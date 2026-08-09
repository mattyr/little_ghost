# frozen_string_literal: true

require "test_helper"

class RunSubagentInstrumentationTest < Minitest::Test
  Agent = Class.new(LittleGhost::Agent) do
    agent_id "main"
  end

  def test_closes_concurrent_subagent_operations_by_operation_id
    recorder = TestInstrumentationSubscriber.new
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [recorder]
    )
    run = build_run
    caller = LittleGhost::Instrumentation.start(:agent, operation_id: "caller", agent_id: "main")
    terminals = {
      "completed" => ["turn_finished", :completed, nil],
      "failed" => ["turn_failed", :error, "ArgumentError"],
      "cancelled" => ["cancelled", :cancelled, nil]
    }
    terminals.each_key do |operation_id|
      publish_subagent(run, "spawned", operation_id:, parent_operation_id: "caller")
    end
    assert_same caller, LittleGhost::Instrumentation.current
    caller.finish(outcome: :completed)

    terminals.to_a.reverse.map do |operation_id, (event, _outcome, error_type)|
      Thread.new do
        publish_subagent(
          run,
          event,
          operation_id:,
          parent_operation_id: "caller",
          error_type:
        )
      end
    end.each(&:join)

    finishes = recorder.events.select { |phase, name, _| phase == :finish && name == :subagent }
    assert_equal terminals.keys.sort, finishes.map { |_, _, attributes| attributes.fetch(:operation_id) }.sort
    terminals.each do |operation_id, (_event, outcome, error_type)|
      attributes = finishes.find { |_, _, values| values[:operation_id] == operation_id }.last
      assert_equal outcome, attributes.fetch(:outcome)
      error_type ? assert_equal(error_type, attributes[:error_type]) : assert_nil(attributes[:error_type])
    end
    refute instrumentation.active?
  end

  def test_run_cleanup_closes_a_subagent_that_cannot_emit_a_terminal_event
    recorder = TestInstrumentationSubscriber.new
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [recorder]
    )
    run = build_run
    caller = LittleGhost::Instrumentation.start(:agent, operation_id: "caller", agent_id: "main")
    publish_subagent(run, "spawned", operation_id: "persisting", parent_operation_id: "caller")

    run.close
    caller.finish(outcome: :completed)

    finish = recorder.events.find do |phase, name, attributes|
      phase == :finish && name == :subagent && attributes[:operation_id] == "persisting"
    end
    assert_equal :cancelled, finish.last.fetch(:outcome)
    refute instrumentation.active?
  end

  private

  def build_run
    LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "hello"),
      agent_class: Agent,
      runtime: TestRuntime.new
    )
  end

  def publish_subagent(run, event, operation_id:, parent_operation_id:, error_type: nil)
    run.publish(
      :subagent,
      event: {
        event:,
        operation_id:,
        parent_operation_id:,
        subagent_id: "/root/research",
        conversation_id: "conversation",
        kind: "deep_research",
        turn: 1,
        error_type:
      }.compact
    )
  end
end
