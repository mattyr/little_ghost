# frozen_string_literal: true

require "test_helper"

class AgentInterruptTest < Minitest::Test
  class SequencedModel
    attr_reader :requests

    def initialize(*responses)
      @responses = Queue.new
      responses.each { |response| @responses << response }
      @requests = []
    end

    def stream(request)
      @requests << request
      response = @responses.pop
      response = response.call(request) if response.respond_to?(:call)
      [LittleGhost::StreamEvent.build(:message_stop, response:)]
    end
  end

  def test_detailed_interrupt_reports_same_response_tool_work_before_it_finishes
    first_started = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    release_second = Queue.new
    first_use = tool_use("first-call", "first")
    second_use = tool_use("second-call", "second")
    first = tool("first") do
      first_started << true
      release_first.pop
      "first result"
    end
    second = tool("second") do
      second_started << true
      release_second.pop
      "second result"
    end
    model = SequencedModel.new(
      model_response(["Starting", first_use], stop_reason: :tool_use),
      lambda do |request|
        assert_includes request.messages.last.text, "Current status?"
        model_response([
          LittleGhost::Content::Text.new(text: "Still checking"),
          LittleGhost::Content::Reasoning.new(text: "private"),
          second_use
        ], stop_reason: :tool_use)
      end,
      model_response("Done")
    )
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      subscribers: [->(name, attributes) { telemetry << [name, attributes] }],
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    agent = LittleGhost::Agent.new(model:, tools: [first, second], instrumentation:)
    runner = Thread.new { agent.call("Investigate") }

    first_started.pop
    interrupted = Thread.new { agent.interrupt_response("Current status?") }
    wait_until { telemetry.any? { |name, _| name == :agent_interrupt_queued } }
    release_first << true
    second_started.pop

    assert interrupted.join(1), "interrupt did not resolve from the next model response"
    assert_equal "Still checking", interrupted.value.text
    assert interrupted.value.tool_calls?
    assert runner.alive?, "child finished before executing its same-response tool"

    delivered_index = telemetry.index { |name, _| name == :agent_interrupt_delivered }
    model_start_indexes = telemetry.each_index.select { |index| telemetry.fetch(index).first == :model_start }
    assert_operator delivered_index, :>, model_start_indexes.fetch(1)

    responded = telemetry.find { |name, _| name == :agent_interrupt_responded }.last
    assert_equal JSON.generate("Still checking"), responded.fetch(:diagnostic_output)
    refute_includes responded.fetch(:diagnostic_output), "private"
    refute_includes responded.fetch(:diagnostic_output), "second-call"

    release_second << true
    assert_equal "Done", runner.value.text
  ensure
    release_first << true if runner&.alive?
    release_second << true if runner&.alive?
    runner&.kill
    interrupted&.kill
    agent&.close
  end

  def test_text_only_interrupt_response_naturally_finishes_the_run
    started = Queue.new
    release = Queue.new
    use = tool_use("work-call", "work")
    work = tool("work") do
      started << true
      release.pop
      "evidence"
    end
    model = SequencedModel.new(
      model_response([use], stop_reason: :tool_use),
      model_response("Best available answer")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("Investigate") }

    started.pop
    interrupted = Thread.new { agent.interrupt("Synthesize now") }
    release << true

    assert_equal "Best available answer", interrupted.value
    assert_equal "Best available answer", runner.value.text
    assert_equal 2, model.requests.length
  ensure
    release << true if runner&.alive?
    runner&.kill
    interrupted&.kill
    agent&.close
  end

  def test_interrupt_arriving_during_terminal_stream_gets_another_model_turn
    streaming = Queue.new
    release = Queue.new
    model = SequencedModel.new(
      lambda do |_request|
        streaming << true
        release.pop
        model_response("Would have finished")
      end,
      model_response("Interrupted response")
    )
    agent = LittleGhost::Agent.new(model:)
    runner = Thread.new { agent.call("Investigate") }

    streaming.pop
    interrupted = Thread.new { agent.interrupt("Before you finish") }
    release << true

    assert_equal "Interrupted response", interrupted.value
    assert_equal "Interrupted response", runner.value.text
    assert_equal 2, model.requests.length
    assert_includes model.requests.last.messages.last.text, "Before you finish"
  ensure
    release << true if runner&.alive?
    runner&.kill
    interrupted&.kill
    agent&.close
  end

  def test_interrupt_rejects_inactive_and_ambiguous_agent_invocations
    agent = LittleGhost::Agent.new(model: SequencedModel.new(model_response("done")))

    assert_raises(LittleGhost::AgentInterruptError) { agent.interrupt("status") }

    first_started = Queue.new
    releases = Queue.new
    blocking_model = Class.new do
      define_method(:initialize) { @started, @releases = first_started, releases }
      define_method(:stream) do |_request|
        @started << true
        @releases.pop
        [LittleGhost::StreamEvent.build(:message_stop, response: AgentInterruptTest.model_response("done"))]
      end
    end.new
    concurrent = LittleGhost::Agent.new(model: blocking_model)
    runners = 2.times.map { Thread.new { concurrent.call("work") } }
    2.times { first_started.pop }

    error = assert_raises(LittleGhost::AgentInterruptError) { concurrent.interrupt("status") }
    assert_includes error.message, "multiple active invocations"
  ensure
    2.times { releases << true } if releases
    runners&.each { |thread| thread.join(1) }
    runners&.each(&:kill)
    concurrent&.close
    agent&.close
  end

  def test_closing_an_agent_releases_a_waiting_interrupt
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response("done")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new { agent.call("Investigate") }

    started.pop
    interrupted = Thread.new do
      agent.interrupt("status")
    rescue => error
      error
    end
    wait_until { interrupted.status == "sleep" }
    agent.close

    assert interrupted.join(1), "closing the agent did not release the interrupt caller"
    assert_instance_of LittleGhost::AgentInterruptError, interrupted.value
  ensure
    release << true if runner&.alive?
    runner&.kill
    interrupted&.kill
    agent&.close
  end

  def test_targeted_interrupt_rejects_a_different_invocation
    started = Queue.new
    release = Queue.new
    work = tool("work") do
      started << true
      release.pop
      "done"
    end
    model = SequencedModel.new(
      model_response([tool_use("work-call", "work")], stop_reason: :tool_use),
      model_response("done")
    )
    agent = LittleGhost::Agent.new(model:, tools: [work])
    runner = Thread.new do
      agent.call("Investigate", parent_operation_id: "current-manager-turn")
    end

    started.pop

    assert_raises(LittleGhost::AgentInterruptError) do
      agent.interrupt("status", target_operation_id: "previous-manager-turn")
    end
    assert runner.alive?

    release << true
    assert_equal "done", runner.value.text
  ensure
    release << true if runner&.alive?
    runner&.kill
    agent&.close
  end

  def test_closed_agent_rejects_a_new_invocation
    agent = LittleGhost::Agent.new(model: SequencedModel.new(model_response("done")))
    agent.close

    error = assert_raises(LittleGhost::InvocationError) { agent.call("work") }

    assert_equal "Agent is closed", error.message
  end

  def self.model_response(content, stop_reason: :end_turn)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:
    )
  end

  def model_response(...) = self.class.model_response(...)

  private

  def tool(name, &implementation)
    LittleGhost::Tool.define(name:, description: name, &implementation)
  end

  def tool_use(id, name)
    LittleGhost::Content::ToolUse.new(id:, name:, input: {})
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
