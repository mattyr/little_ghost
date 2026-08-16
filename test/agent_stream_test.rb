# frozen_string_literal: true

require "test_helper"

class AgentStreamTest < Minitest::Test
  class ScriptedModel
    include LittleGhost::ModelInterface

    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def stream(request)
      requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: response.message.text),
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  class Barrier
    def initialize(parties)
      @parties = parties
      @arrived = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @arrived += 1
        @condition.broadcast if @arrived == @parties
        @condition.wait(@mutex) while @arrived < @parties
      end
    end
  end

  class BarrierModel < ScriptedModel
    def initialize(barrier, response)
      @barrier = barrier
      super(response)
    end

    def stream(request)
      @barrier.wait
      super
    end
  end

  class Runtime
    attr_reader :models

    def initialize(models)
      @models = models.transform_values { |values| Array(values).dup }
      @agent_factory = LittleGhost::AgentFactory.new(
        runtime: self,
        prompt_paths: [],
        resolve_agent: ->(reference) { reference }
      )
    end

    def build_assembly(reference, run:, agent_stream_path: [])
      return build_agent(reference, run:, agent_stream_path:) if reference <= LittleGhost::Agent

      child = reference.new(run:, runtime: self)
      child.bind_agent_stream_path(agent_stream_path)
    end

    def build_agent(
      reference,
      run:,
      tools: [],
      agent_path: LittleGhost::Subagents::AgentPath::ROOT,
      agent_stream_path: [],
      **
    )
      @agent_factory.build(reference, run:, tools:, agent_path:, agent_stream_path:)
    end

    def model_for(agent_class, _run) = models.fetch(agent_class).shift
    def open_session(_run) = nil
    def service_name = "agent-stream-test"
    def template_locals(run:, agent:) = {run:, agent:}
    def error_message(error, _run) = "Agent failed: #{error.class}"
  end

  def test_contextual_agent_events_are_opt_in
    support_agent = agent_class("support")

    ordinary = run_for(support_agent, models: {
      support_agent => ScriptedModel.new(response("hello"))
    }).to_a
    contextual = run_for(support_agent, include_agent_events: true, models: {
      support_agent => ScriptedModel.new(response("hello"))
    }).to_a

    refute_includes ordinary.map(&:type), :agent_stream
    assert_equal ordinary.map(&:type), contextual.reject { |event| event.type == :agent_stream }.map(&:type)
    wrappers = contextual.select { |event| event.type == :agent_stream }
    assert_equal %i[
      invocation_start model_start message_start text_delta message_stop model_stop invocation_stop
    ], wrappers.map { |event| event.data.fetch(:event).type }
    assert_empty wrappers.first.data.fetch(:source).assembly_path
    assert_equal "hello", wrappers.last.data.fetch(:event).data.fetch(:result).text
    raw_stop = contextual.each_index.find do |index|
      index > contextual.index(wrappers.last) && contextual.fetch(index).type == :invocation_stop
    end
    assert_operator contextual.index(wrappers.last), :<, raw_stop
  end

  def test_graph_events_include_routed_inputs_and_assembly_paths
    planner = agent_class("planner")
    writer = agent_class("writer")
    graph = Class.new(LittleGhost::Graph) do
      assembly_id "support_graph"
      node :plan, planner
      node :write, writer
      start :plan
      edge :plan, :write
      finish :write
    end
    events = run_for(graph, include_agent_events: true, models: {
      planner => ScriptedModel.new(response("collect evidence")),
      writer => ScriptedModel.new(response("final answer"))
    }).to_a
    starts = agent_events(events, :invocation_start)

    assert_equal %w[planner writer], starts.map { |event| event.data.fetch(:source).agent_id }
    assert_equal "request", starts.first.data.fetch(:input).text
    assert_includes starts.last.data.fetch(:input).text, "plan output:\ncollect evidence"
    assert_equal(%w[plan write], starts.map do |event|
      event.data.fetch(:source).assembly_path.fetch(0).participant
    end)
    assert starts.all? { |event| event.data.fetch(:source).assembly_path.frozen? }
    writer_events = events.select do |event|
      event.type == :agent_stream && event.data.fetch(:source).agent_id == "writer"
    end
    assert_equal 1, writer_events.map { |event| event.data.fetch(:source).operation_id }.uniq.length
  end

  def test_nested_assemblies_append_to_the_agent_path
    researcher = agent_class("researcher")
    inner = Class.new(LittleGhost::Graph) do
      assembly_id "research_graph"
      node :research, researcher
      start :research
      finish :research
    end
    outer = Class.new(LittleGhost::Graph) do
      assembly_id "support_graph"
      node :investigate, inner
      start :investigate
      finish :investigate
    end
    events = run_for(outer, include_agent_events: true, models: {
      researcher => ScriptedModel.new(response("evidence"))
    }).to_a
    source = agent_events(events, :invocation_start).fetch(0).data.fetch(:source)

    assert_equal %w[support_graph research_graph], source.assembly_path.map(&:assembly_id)
    assert_equal %w[investigate research], source.assembly_path.map(&:participant)
  end

  def test_workflow_agents_include_the_invocation_name_in_their_path
    responder = agent_class("responder")
    workflow = Class.new(LittleGhost::Workflow) do
      assembly_id "response_workflow"

      define_method(:perform) do
        invoke responder, as: :answer
      end

      private :perform
    end
    events = run_for(workflow, include_agent_events: true, models: {
      responder => ScriptedModel.new(response("answer"))
    }).to_a
    step = agent_events(events, :invocation_start).fetch(0).data.fetch(:source).assembly_path.fetch(0)

    assert_equal :workflow, step.assembly_kind
    assert_equal "response_workflow", step.assembly_id
    assert_equal "answer", step.participant
  end

  def test_swarm_agents_stream_before_and_after_a_handoff
    triage = agent_class("triage")
    responder = agent_class("responder")
    handoff = LittleGhost::Content::ToolUse.new(
      id: "handoff-1",
      name: "handoff_to_agent",
      input: {"agent_id" => "responder", "message" => "answer the request"}
    )
    swarm = Class.new(LittleGhost::Swarm) do
      assembly_id "support_swarm"
      member triage
      member responder
      start triage
    end
    events = run_for(swarm, include_agent_events: true, models: {
      triage => ScriptedModel.new(response([handoff], stop_reason: :tool_use)),
      responder => ScriptedModel.new(response("answer"))
    }).to_a
    starts = agent_events(events, :invocation_start)

    assert_equal %w[triage responder], starts.map { |event| event.data.fetch(:source).agent_id }
    assert_equal([:swarm], starts.map do |event|
      event.data.fetch(:source).assembly_path.fetch(0).assembly_kind
    end.uniq)
    assert_equal(%w[triage responder], starts.map do |event|
      event.data.fetch(:source).assembly_path.fetch(0).participant
    end)
  end

  def test_agent_tools_stream_the_child_with_the_invoking_agent_as_parent
    researcher = agent_class("researcher")
    researcher.description "Researches a request."
    tool_use = LittleGhost::Content::ToolUse.new(
      id: "research-1",
      name: "researcher",
      input: {"input" => "find evidence"}
    )
    coordinator = Class.new(LittleGhost::Agent) do
      agent_id "coordinator"
      system_prompt ""
      agent_as_tool researcher
    end
    events = run_for(coordinator, include_agent_events: true, models: {
      coordinator => ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response("done")),
      researcher => ScriptedModel.new(response("evidence"))
    }).to_a
    starts = agent_events(events, :invocation_start)
    assert_equal %w[coordinator researcher], starts.map { |event| event.data.fetch(:source).agent_id }
    parent = starts.find { |event| event.data.fetch(:source).agent_id == "coordinator" }.data.fetch(:source)
    child_event = starts.find { |event| event.data.fetch(:source).agent_id == "researcher" }
    child = child_event.data.fetch(:source)

    assert_equal "find evidence", child_event.data.fetch(:input).text
    assert_equal parent.operation_id, child.parent_operation_id
    assert_empty child.assembly_path
  end

  def test_agent_failures_are_published_before_the_run_error
    support_agent = agent_class("support")
    events = run_for(support_agent, include_agent_events: true, models: {
      support_agent => ScriptedModel.new(RuntimeError.new("provider failed"))
    }).to_a
    failure = agent_events(events, :invocation_error).fetch(0)

    assert_instance_of RuntimeError, failure.data.fetch(:event).data.fetch(:error)
    assert_equal :run_error, events.last.type
    assert_operator events.index(failure), :<, events.length - 1
  end

  def test_managed_subagents_stream_with_their_stable_agent_path
    researcher = agent_class("researcher")
    researcher.description "Researches a request."
    spawn = LittleGhost::Content::ToolUse.new(
      id: "spawn-1",
      name: "spawn_subagent",
      input: {
        "kind" => "researcher",
        "task_name" => "investigate",
        "task" => "find evidence",
        "mode" => "sync"
      }
    )
    coordinator = Class.new(LittleGhost::Agent) do
      agent_id "coordinator"
      system_prompt ""
      subagent researcher, persist: false
    end
    events = run_for(coordinator, include_agent_events: true, models: {
      coordinator => ScriptedModel.new(response([spawn], stop_reason: :tool_use), response("done")),
      researcher => ScriptedModel.new(response("evidence"))
    }).to_a
    starts = agent_events(events, :invocation_start)
    parent = starts.find { |event| event.data.fetch(:source).agent_id == "coordinator" }.data.fetch(:source)
    child_event = starts.find { |event| event.data.fetch(:source).agent_id == "researcher" }
    child = child_event.data.fetch(:source)
    turn = events.filter_map do |event|
      next unless event.type == :subagent

      event.data.fetch(:event) if event.data.fetch(:event).fetch(:event) == "turn_started"
    end.fetch(0)

    assert_equal "find evidence", child_event.data.fetch(:input).text
    assert_equal "/root/investigate", child.agent_path
    refute_equal parent.operation_id, child.parent_operation_id
    assert_equal turn.fetch(:operation_id), child.parent_operation_id
  end

  def test_dynamic_subagents_inherit_the_enclosing_assembly_path
    researcher = agent_class("researcher")
    researcher.description "Researches a request."
    spawn = LittleGhost::Content::ToolUse.new(
      id: "spawn-1",
      name: "spawn_subagent",
      input: {
        "kind" => "researcher",
        "task_name" => "investigate",
        "task" => "find evidence",
        "mode" => "sync"
      }
    )
    coordinator = Class.new(LittleGhost::Agent) do
      agent_id "coordinator"
      system_prompt ""
      subagents do |run|
        [
          LittleGhost::Subagents::Definition.new(
            kind: "researcher",
            description: "Researches a request.",
            factory: lambda do |agent_path, runtime:|
              runtime.build_agent(researcher, run:, agent_path:)
            end
          )
        ]
      end
    end
    graph = Class.new(LittleGhost::Graph) do
      assembly_id "support_graph"
      node :coordinate, coordinator
      start :coordinate
      finish :coordinate
    end
    events = run_for(graph, include_agent_events: true, models: {
      coordinator => ScriptedModel.new(response([spawn], stop_reason: :tool_use), response("done")),
      researcher => ScriptedModel.new(response("evidence"))
    }).to_a
    child = agent_events(events, :invocation_start)
      .find { |event| event.data.fetch(:source).agent_id == "researcher" }
      .data.fetch(:source)

    assert_equal "/root/investigate", child.agent_path
    assert_equal ["support_graph"], child.assembly_path.map(&:assembly_id)
    assert_equal ["coordinate"], child.assembly_path.map(&:participant)
  end

  def test_parallel_agents_never_invoke_the_stream_consumer_concurrently
    planner = agent_class("planner")
    researcher = agent_class("researcher")
    verifier = agent_class("verifier")
    writer = agent_class("writer")
    graph = Class.new(LittleGhost::Graph) do
      node :plan, planner
      node :research, researcher
      node :verify, verifier
      node :write, writer
      start :plan
      fork :plan, to: [:research, :verify], max_concurrency: 2
      join [:research, :verify], to: :write
      finish :write
    end
    barrier = Barrier.new(2)
    run = run_for(graph, include_agent_events: true, models: {
      planner => ScriptedModel.new(response("plan")),
      researcher => BarrierModel.new(barrier, response("evidence")),
      verifier => BarrierModel.new(barrier, response("verified")),
      writer => ScriptedModel.new(response("done"))
    })
    mutex = Mutex.new
    active = 0
    concurrent = false

    run.each do |event|
      next unless event.type == :agent_stream
      next unless event.data.fetch(:event).type == :text_delta

      mutex.synchronize do
        active += 1
        concurrent = true if active > 1
      end
      100.times { Thread.pass }
    ensure
      mutex.synchronize { active -= 1 } if event&.type == :agent_stream && active.positive?
    end

    refute concurrent
    assert run.completed?
  end

  def test_include_agent_events_rejects_non_boolean_values
    agent = agent_class("support")
    invocation = LittleGhost::Invocation.new(message: "request", include_agent_events: "yes")

    error = assert_raises(LittleGhost::InvocationError) do
      LittleGhost::Run.new(invocation:, runtime: Runtime.new({}), entrypoint_class: agent)
    end

    assert_equal "include_agent_events must be true or false", error.message
  end

  def test_source_values_are_immutable_without_freezing_caller_strings
    agent_id = +"support"
    operation_id = +"agent-1"
    source = LittleGhost::AgentStreamSource.build(
      agent_id:,
      agent_path: "/root",
      operation_id:,
      parent_operation_id: "run-1",
      assembly_path: []
    )

    refute agent_id.frozen?
    refute operation_id.frozen?
    assert source.frozen?
    assert source.agent_id.frozen?
    assert source.assembly_path.frozen?
  end

  def test_contextual_values_cannot_mutate_live_input_or_results
    support_agent = agent_class("support")
    model = ScriptedModel.new(response("safe answer"))
    run = run_for(support_agent, include_agent_events: true, models: {support_agent => model})
    mutation_errors = []

    run.each do |event|
      next unless event.type == :agent_stream

      agent_event = event.data.fetch(:event)
      target = case agent_event.type
      when :invocation_start
        event.data.fetch(:input).content.fetch(0).text
      when :invocation_stop
        agent_event.data.fetch(:result).message.content.fetch(0).text
      end
      mutation_errors << assert_raises(FrozenError) { target.replace("tampered") } if target
    end

    assert_equal "request", model.requests.fetch(0).messages.last.text
    assert_equal "safe answer", run.response
    assert_equal 2, mutation_errors.length
  end

  def test_contextual_errors_detach_native_message_and_backtrace_state
    support_agent = agent_class("support")
    provider_error = RuntimeError.new(+"provider failed")
    root_cause = ArgumentError.new(+"root cause")
    begin
      raise provider_error, cause: root_cause
    rescue RuntimeError => raised
      provider_error = raised
    end
    provider_error.set_backtrace([+"provider.rb:1"])
    run = run_for(support_agent, include_agent_events: true, models: {
      support_agent => ScriptedModel.new(provider_error)
    })
    snapshot = nil

    run.each do |event|
      next unless event.type == :agent_stream
      next unless event.data.fetch(:event).type == :invocation_error

      snapshot = event.data.fetch(:event).data.fetch(:error)
      assert_raises(FrozenError) { snapshot.message.replace("tampered") }
      assert_raises(FrozenError) { snapshot.backtrace.fetch(0).replace("tampered.rb:1") }
      assert_raises(FrozenError) { snapshot.backtrace << "extra.rb:1" }
      assert_raises(FrozenError) { snapshot.cause.message.replace("tampered cause") }
    end

    refute_same provider_error, snapshot
    refute_same provider_error.message, snapshot.message
    refute_same provider_error.backtrace, snapshot.backtrace
    refute_same provider_error.cause, snapshot.cause
    assert_equal "provider failed", run.error.message
    assert_equal ["provider.rb:1"], run.error.backtrace
    assert_equal "root cause", run.error.cause.message
  end

  private

  def agent_class(id)
    Class.new(LittleGhost::Agent) do
      agent_id id
      system_prompt ""
    end
  end

  def run_for(entrypoint, models:, include_agent_events: false)
    invocation = LittleGhost::Invocation.new(message: "request", include_agent_events:)
    LittleGhost::Run.new(
      invocation:,
      runtime: Runtime.new(models),
      entrypoint_class: entrypoint
    )
  end

  def agent_events(events, type)
    events.select do |event|
      event.type == :agent_stream && event.data.fetch(:event).type == type
    end
  end

  def response(content, stop_reason: :end_turn)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:,
      usage: LittleGhost::Usage.new
    )
  end
end
