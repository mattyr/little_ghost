# frozen_string_literal: true

require "test_helper"

class SwarmTest < Minitest::Test
  class FirstAgent < LittleGhost::Agent
    description "Routes requests"
  end

  class SecondAgent < LittleGhost::Agent
    description "Answers requests"
  end

  class FakeAgent
    attr_reader :calls, :tools
    attr_accessor :assembly_transition

    def self.assembly_id = "fake_agent"
    def self.assembly_kind = :agent

    def initialize(result:, transition: nil, failure_usage: LittleGhost::Usage.new)
      @result = result
      @assembly_transition = transition
      @failure_usage = failure_usage
      @tools = Object.new
    end

    def stream(input, **options)
      @calls = [input, options]
      if @result.is_a?(Exception)
        return Enumerator.new do |events|
          events << LittleGhost::StreamEvent.build(
            :invocation_error,
            error: @result,
            usage: @failure_usage,
            metadata: {}
          )
          raise @result
        end
      end
      [
        LittleGhost::StreamEvent.build(:text_delta, text: @result.text),
        LittleGhost::StreamEvent.build(:invocation_stop, result: @result)
      ].each
    end

    def interject(...) = nil
    def bind_agent_stream_path(_path) = self
    def close = @closed = true
    def closed? = @closed == true
  end

  class Runtime
    attr_reader :built

    def initialize(agents)
      @agents = agents.transform_values(&:dup)
      @built = []
    end

    def build_agent(agent_class, run:, tools:, agent_stream_path:)
      agent = @agents.fetch(agent_class).shift
      agent.bind_agent_stream_path(agent_stream_path)
      agent.tools.define_singleton_method(:fetch) do |_name|
        raise KeyError unless tools.first

        tools.first.allocate
      end
      built << [agent_class, run, tools]
      agent
    end

    def template_locals(run:, agent:) = {run:, agent:}
  end

  Run = Struct.new(:runtime, :workspace, :sandbox)

  def test_hides_handoff_content_and_streams_the_final_member
    swarm_class = Class.new(LittleGhost::Swarm) do
      member FirstAgent
      member SecondAgent
      start FirstAgent
    end
    first = FakeAgent.new(
      result: result("private route", input_tokens: 2),
      transition: {agent_id: SecondAgent.agent_id, message: "Please answer", context: {"topic" => "refund"}}
    )
    second = FakeAgent.new(result: result("final answer", input_tokens: 5))
    runtime = Runtime.new(FirstAgent => [first], SecondAgent => [second])

    events = swarm_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal %i[
      assembly_step_start assembly_step_stop assembly_transition
      assembly_step_start assembly_step_stop text_delta invocation_stop
    ], events.map(&:type)
    refute events.any? { |event| event.type == :text_delta && event.data[:text] == "private route" }
    assert_equal "final answer", events.find { |event| event.type == :text_delta }.data.fetch(:text)
    assert_equal 7, events.last.data.fetch(:result).usage.input_tokens
    assert_includes second.calls.first.text, "Handoff from first:"
    assert_includes second.calls.first.text, "Please answer"
    assert_includes second.calls.first.text, '"topic":"refund"'
    assert_empty second.calls.fetch(1).fetch(:history)
    assert_nil first.calls.fetch(1).fetch(:checkpoint)
    assert_nil second.calls.fetch(1).fetch(:checkpoint)
    assert first.closed?
    assert second.closed?
  end

  def test_rejects_invalid_member_sets
    swarm_class = Class.new(LittleGhost::Swarm) do
      member FirstAgent
      start FirstAgent
    end

    error = assert_raises(LittleGhost::ConfigurationError) { swarm_class.swarm_definition! }

    assert_includes error.message, "at least two members"
  end

  def test_rejects_non_agents
    swarm_class = Class.new(LittleGhost::Swarm)

    error = assert_raises(LittleGhost::ConfigurationError) { swarm_class.member(LittleGhost::Workflow) }

    assert_includes error.message, "Agent definitions"
  end

  def test_standalone_stream_uses_the_callers_cancellation_token
    token = LittleGhost::Support::CancellationToken.new
    captured = nil
    runtime = Object.new
    runtime.define_singleton_method(:build_run) do |_payload, **options|
      captured = options.fetch(:cancellation_token)
      [].each
    end

    Class.new(LittleGhost::Swarm).new(runtime:).stream("request", cancellation_token: token).to_a

    assert_same token, captured
  end

  def test_rejects_oversized_and_overly_nested_buffered_events
    swarm = Class.new(LittleGhost::Swarm).new(runtime: Object.new)
    oversized = LittleGhost::StreamEvent.build(
      :message_stop,
      metadata: {content: "x" * (LittleGhost::Swarm::MAX_BUFFERED_EVENT_BYTES + 1)}
    )
    nested = "small"
    34.times { nested = [nested] }
    overly_nested = LittleGhost::StreamEvent.build(:message_stop, metadata: {content: nested})

    assert_raises(LittleGhost::AssemblyLimitError) do
      swarm.send(:buffer_event!, [], oversized, bytes: 0)
    end
    assert_raises(LittleGhost::AssemblyLimitError) do
      swarm.send(:buffer_event!, [], overly_nested, bytes: 0)
    end
  end

  def test_validates_declared_handoff_topology
    swarm_class = Class.new(LittleGhost::Swarm) do
      member FirstAgent
      member SecondAgent
      start FirstAgent
      handoff FirstAgent, to: [SecondAgent]
      max_handoff_repeats 2
    end

    members, start, topology = swarm_class.swarm_definition!

    assert_equal FirstAgent.agent_id, start
    assert_equal [SecondAgent.agent_id], topology.first.to
    assert_equal 2, swarm_class.max_handoff_repeats
    assert_equal 2, members.length
  end

  def test_terminal_topology_member_receives_no_handoff_tool
    swarm_class = Class.new(LittleGhost::Swarm) do
      member FirstAgent
      member SecondAgent
      start FirstAgent
      handoff FirstAgent, to: [SecondAgent]
    end
    first = FakeAgent.new(
      result: result("route"),
      transition: {agent_id: SecondAgent.agent_id, message: "finish"}
    )
    second = FakeAgent.new(result: result("done"))
    runtime = Runtime.new(FirstAgent => [first], SecondAgent => [second])

    swarm_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal 1, runtime.built.first.fetch(2).length
    assert_empty runtime.built.last.fetch(2)
  end

  def test_accepts_agent_builder_members_and_rejects_composite_builders
    first = LittleGhost::AgentBuilder.new(id: "first")
    second = LittleGhost::AgentBuilder.new(id: "second")
    swarm = LittleGhost::SwarmBuilder.new
    swarm.member(first).member(second).start(:first)

    assert_equal :swarm, swarm.definition.kind

    invalid = LittleGhost::SwarmBuilder.new
    invalid.member(LittleGhost::WorkflowBuilder.new)
    error = assert_raises(LittleGhost::ConfigurationError) { invalid.validate! }
    assert_includes error.message, "Agent definitions"
  end

  def test_reports_failed_member_usage
    swarm_class = Class.new(LittleGhost::Swarm) do
      member FirstAgent
      member SecondAgent
      start FirstAgent
    end
    error = RuntimeError.new("failed")
    first = FakeAgent.new(
      result: error,
      failure_usage: LittleGhost::Usage.new(input_tokens: 7)
    )
    runtime = Runtime.new(FirstAgent => [first], SecondAgent => [])
    events = []

    assert_raises(RuntimeError) do
      swarm_class.new(run: Run.new(runtime), runtime:).stream("request").each { |event| events << event }
    end

    assert_equal 7, events.last.data.fetch(:usage).input_tokens
  end

  def test_bounds_handoff_output_and_validates_member_policies
    swarm = Class.new(LittleGhost::Swarm).new(runtime: Object.new)
    step = LittleGhost::Assembly::Step.new(
      id: "step",
      participant: "first",
      assembly_id: "first",
      assembly_kind: :agent,
      status: :completed,
      attempts: [],
      usage: LittleGhost::Usage.new
    )
    sanitized = swarm.send(
      :sanitized_handoff_step,
      step,
      {agent_id: "second", message: "x" * (LittleGhost::Assembly::MAX_STEP_OUTPUT_BYTES + 1)}
    )

    assert_nil sanitized.output
    assert sanitized.output_truncated

    builder = LittleGhost::SwarmBuilder.new
      .member(FirstAgent, timeout: -1)
      .member(SecondAgent)
      .start(FirstAgent)
    assert_raises(ArgumentError) { builder.validate! }
  end

  private

  def result(text, input_tokens: 0)
    LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: text),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens:),
      messages: [],
      state: {},
      structured_result: nil
    )
  end
end
