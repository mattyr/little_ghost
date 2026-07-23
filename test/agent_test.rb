# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"

class AgentTest < Minitest::Test
  class ScriptedModel
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def stream(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: response.message.text),
        LittleGhost::StreamEvent.build(:message_stop, response: response)
      ].each
    end
  end

  class EventModel
    attr_reader :requests

    def initialize(*streams)
      @streams = streams
      @requests = []
    end

    def stream(request)
      @requests << request
      @streams.shift.each
    end
  end

  def test_runs_model_and_returns_normalized_result
    model = ScriptedModel.new(response("hello", usage: LittleGhost::Usage.new(input_tokens: 2, output_tokens: 1)))

    result = LittleGhost::Agent.new(model: model).call("hi")

    assert_equal "hello", result.text
    assert_equal 3, result.usage.total_tokens
    assert_equal %i[user assistant], result.messages.map(&:role)
  end

  def test_rejects_terminal_model_output_limits
    %i[max_tokens limit_output_tokens limit_total_tokens limit_turns].each do |stop_reason|
      model = ScriptedModel.new(response("incomplete", stop_reason: stop_reason))

      error = assert_raises(LittleGhost::OutputLimitError) do
        LittleGhost::Agent.new(model: model).call("hi")
      end

      assert_equal "The model stopped before completing its response", error.message
    end
  end

  def test_model_retry_discards_an_earlier_terminal_response
    model = EventModel.new([
      LittleGhost::StreamEvent.build(:message_stop, response: response("discarded")),
      LittleGhost::StreamEvent.build(:model_retry, attempt: 1, delay: 0)
    ])

    assert_raises(LittleGhost::ProtocolError) { LittleGhost::Agent.new(model:).call("hi") }
  end

  def test_model_retry_executes_only_tools_from_the_successful_attempt
    calls = []
    stale_tool = LittleGhost::Tool.define(name: "stale", description: "Stale") { calls << :stale }
    current_tool = LittleGhost::Tool.define(name: "current", description: "Current") do
      calls << :current
      "found"
    end
    stale_use = LittleGhost::Content::ToolUse.new(id: "stale-1", name: "stale", input: {})
    current_use = LittleGhost::Content::ToolUse.new(id: "current-1", name: "current", input: {})
    model = EventModel.new(
      [
        LittleGhost::StreamEvent.build(:tool_call_start, index: 0, id: stale_use.id, name: stale_use.name),
        LittleGhost::StreamEvent.build(:tool_call_stop, index: 0, tool_use: stale_use),
        LittleGhost::StreamEvent.build(:message_stop, response: response([stale_use], stop_reason: :tool_use)),
        LittleGhost::StreamEvent.build(:model_retry, attempt: 1, delay: 0),
        LittleGhost::StreamEvent.build(:tool_call_start, index: 0, id: current_use.id, name: current_use.name),
        LittleGhost::StreamEvent.build(:tool_call_stop, index: 0, tool_use: current_use),
        LittleGhost::StreamEvent.build(:message_stop, response: response([current_use], stop_reason: :tool_use))
      ],
      [LittleGhost::StreamEvent.build(:message_stop, response: response("done"))]
    )

    result = LittleGhost::Agent.new(model:, tools: [stale_tool, current_tool]).call("hi")

    assert_equal "done", result.text
    assert_equal [:current], calls
    assert_equal "current-1", model.requests.last.messages.last.content.first.tool_use_id
  end

  def test_cleanup_errors_cannot_be_recovered_by_model_error_callbacks
    cleanup_error = LittleGhost::CleanupError.new("model work is still running")
    recovery_attempts = 0
    agent_class = Class.new(LittleGhost::Agent) do
      after_model_error do |payload|
        recovery_attempts += 1
        LittleGhost::Support::Callbacks.replace(payload)
      end
    end
    model = ScriptedModel.new(cleanup_error, response("must not continue"))
    agent = agent_class.new(model:)

    raised = assert_raises(LittleGhost::CleanupError) { agent.call("hi") }

    assert_same cleanup_error, raised
    assert_equal 0, recovery_attempts
    assert_equal 1, model.requests.length
  ensure
    agent&.close
  end

  def test_executes_tool_calls_and_returns_results_to_model
    tool = LittleGhost::Tool.define(name: "echo", description: "Echo", input_schema: {type: "object"}) do |input|
      input.fetch("value")
    end
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "echo", input: {"value" => "found"})
    model = ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response("done"))

    result = LittleGhost::Agent.new(model: model, tools: [tool]).call("go")

    assert_equal "done", result.text
    result_block = model.requests.last.messages.last.content.first
    assert_equal "found", result_block.content
    assert_equal :success, result_block.status
  end

  def test_streams_parallel_tool_results_as_they_finish_without_reordering_model_results
    slow_started = Queue.new
    release_slow = Queue.new
    tool_stops = Queue.new
    slow_tool = LittleGhost::Tool.define(name: "slow", description: "Slow") do
      slow_started << true
      release_slow.pop
      "slow result"
    end
    fast_tool = LittleGhost::Tool.define(name: "fast", description: "Fast") { "fast result" }
    tool_uses = [
      LittleGhost::Content::ToolUse.new(id: "slow-call", name: "slow", input: {}),
      LittleGhost::Content::ToolUse.new(id: "fast-call", name: "fast", input: {})
    ]
    model = ScriptedModel.new(response(tool_uses, stop_reason: :tool_use), response("done"))
    agent = LittleGhost::Agent.new(model:, tools: [slow_tool, fast_tool])
    runner = Thread.new do
      agent.stream("go").each { |event| tool_stops << event if event.type == :tool_stop }
    end

    assert slow_started.pop(timeout: 1), "slow tool did not start"
    first_stop = tool_stops.pop(timeout: 1)
    refute_nil first_stop, "fast tool result did not stream while the slow tool was blocked"
    assert_equal "fast-call", first_stop.data.fetch(:tool_use).id

    release_slow << true
    assert runner.join(1), "agent did not finish after the slow tool was released"
    result_message = model.requests.last.messages.last
    assert_equal %w[slow-call fast-call], result_message.content.map(&:tool_use_id)
  ensure
    release_slow << true if release_slow && runner&.alive?
    runner&.join(1)
    runner&.kill
    agent&.close
  end

  def test_instruments_agent_model_and_tool_operations_without_content
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })
    tool = LittleGhost::Tool.define(name: "echo", description: "Echo") { |input| input.fetch("value") }
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "echo", input: {"value" => "secret"})
    model = ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response("done"))
    agent = LittleGhost::Agent.new(model:, tools: [tool], instrumentation:)

    agent.call("private prompt", parent_operation_id: "subagent-turn")

    agent_start = telemetry.assoc(:agent_start).last
    agent_stop = telemetry.assoc(:agent_stop).last
    model_starts = telemetry.filter_map { |name, attributes| attributes if name == :model_start }
    model_stops = telemetry.filter_map { |name, attributes| attributes if name == :model_stop }
    turn_starts = telemetry.filter_map { |name, attributes| attributes if name == :agent_turn_start }
    turn_stops = telemetry.filter_map { |name, attributes| attributes if name == :agent_turn_stop }
    tool_start = telemetry.assoc(:tool_start).last
    tool_stop = telemetry.assoc(:tool_stop).last

    assert_equal agent_start[:operation_id], agent_stop[:operation_id]
    assert_equal "subagent-turn", agent_start[:parent_operation_id]
    assert_equal model_starts.map { |event| event[:operation_id] }, model_stops.map { |event| event[:operation_id] }
    assert_equal turn_starts.map { |event| event[:operation_id] }, turn_stops.map { |event| event[:operation_id] }
    assert turn_starts.all? { |event| event[:parent_operation_id] == agent_start[:operation_id] }
    assert_equal turn_starts.map { |event| event[:operation_id] }, model_starts.map { |event| event[:parent_operation_id] }
    assert_equal turn_starts.first[:operation_id], tool_start[:parent_operation_id]
    assert_equal tool_start[:operation_id], tool_stop[:operation_id]
    assert_equal "echo", tool_start[:tool_name]
    assert_equal :success, tool_stop[:outcome]
    refute tool_start.key?(:input)
    assert_equal "call-1", tool_start[:tool_call_id]
    refute model_starts.first.key?(:messages)
    refute model_starts.first.key?(:diagnostic_tool_definitions)
  ensure
    agent&.close
  end

  def test_explicit_capture_records_model_tool_and_reasoning_content_without_binary_data
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })
    tool = LittleGhost::Tool.define(name: "echo", description: "Echo") { |input| input.fetch("value") }
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "echo", input: {"value" => "found"})
    final_content = [
      LittleGhost::Content::Reasoning.new(text: "private reasoning"),
      LittleGhost::Content::Text.new(text: "done")
    ]
    model = ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response(final_content))
    agent = LittleGhost::Agent.new(model:, tools: [tool], instrumentation:)

    agent.call("private prompt")

    assert_equal "private prompt", JSON.parse(telemetry.assoc(:agent_start).last.fetch(:diagnostic_input))
    tool_input = JSON.parse(telemetry.assoc(:tool_start).last.fetch(:diagnostic_input))
    assert_equal "found", tool_input.fetch("value")
    definitions = JSON.parse(telemetry.assoc(:model_start).last.fetch(:diagnostic_tool_definitions))
    assert_equal "echo", definitions.first.fetch("name")
    tool_start = telemetry.assoc(:tool_start).last
    tool_definition = JSON.parse(tool_start.fetch(:diagnostic_tool_definitions)).first
    assert_equal "Echo", tool_definition.fetch("description")
    assert_equal({}, tool_definition.fetch("input_schema"))
    tool_output = JSON.parse(telemetry.assoc(:tool_stop).last.fetch(:diagnostic_output))
    assert_equal "found", tool_output
    final_output = JSON.parse(telemetry.filter_map { |name, value| value if name == :model_stop }.last.fetch(:diagnostic_output))
    reasoning = final_output.fetch("content").find { |block| block.fetch("type") == "reasoning" }
    assert_equal "private reasoning", reasoning.fetch("text")
  ensure
    agent&.close
  end

  def test_tool_failure_telemetry_retains_the_original_exception
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })
    tool = LittleGhost::Tool.define(name: "broken", description: "Fails") do
      raise FrozenError, "live state was frozen"
    end
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "broken", input: {})
    model = ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response("recovered"))
    agent = LittleGhost::Agent.new(model:, tools: [tool], instrumentation:)

    agent.call("try the tool")

    stop = telemetry.assoc(:tool_stop).last
    assert_equal "FrozenError", stop.fetch(:error_type)
    exception = JSON.parse(stop.fetch(:diagnostic_exception))
    assert_equal "FrozenError", exception.fetch("type")
    assert_equal "live state was frozen", exception.fetch("message")
    assert_equal "Tool failed (FrozenError)", JSON.parse(stop.fetch(:diagnostic_output))
  ensure
    agent&.close
  end

  def test_returns_unknown_tools_to_the_model_as_errors
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "missing", input: {})
    model = ScriptedModel.new(response([tool_use], stop_reason: :tool_use), response("recovered"))

    result = LittleGhost::Agent.new(model: model, instrumentation:).call("go")

    assert_equal "recovered", result.text
    assert_equal :error, model.requests.last.messages.last.content.first.status
    assert_equal "unknown_tool", telemetry.assoc(:tool_start).last.fetch(:tool_name)
    assert_equal "call-1", telemetry.assoc(:tool_start).last.fetch(:tool_call_id)
  end

  def test_agents_can_be_exposed_as_tools
    model = ScriptedModel.new(response("delegated"))
    tool = LittleGhost::Agent.new(model: model).as_tool

    result = tool.execute({"input" => "work"})

    assert_equal "agent", tool.tool_name
    assert_equal "Delegate a task to agent.", tool.description
    assert_equal "delegated", result.content
  end

  def test_agent_tool_closes_the_child_agent
    child_tool = Class.new(LittleGhost::Tool) do
      tool_name "child_resource"
      description "Child resource"
      attr_reader :closed

      def close = @closed = true
    end
    child = LittleGhost::Agent.new(model: ScriptedModel.new(response("delegated")), tools: [child_tool])
    wrapper = child.as_tool

    wrapper.close

    assert child.tool_registry.fetch("child_resource").closed
  end

  def test_mixed_exclusive_and_agent_tool_batch_does_not_hold_the_run_lock_during_delegation
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "go"),
      application: Object.new
    )
    exclusive_tool = Class.new(LittleGhost::Tool) do
      tool_name "mutate"
      description "Mutate"
      exclusive true
      def call(_input, context:) = "mutated"
    end
    child_use = LittleGhost::Content::ToolUse.new(id: "child-call", name: "mutate", input: {})
    child_class = Class.new(LittleGhost::Agent) { system_prompt "" }
    child = child_class.new(
      model: ScriptedModel.new(response([child_use], stop_reason: :tool_use), response("delegated")),
      tools: [exclusive_tool],
      run:
    )
    child_tool = child.as_tool(name: "delegate", description: "Delegate")
    parent_uses = [
      LittleGhost::Content::ToolUse.new(id: "parent-call", name: "mutate", input: {}),
      LittleGhost::Content::ToolUse.new(id: "delegate-call", name: "delegate", input: {"input" => "work"})
    ]
    parent_class = Class.new(LittleGhost::Agent) { system_prompt "" }
    parent = parent_class.new(
      model: ScriptedModel.new(response(parent_uses, stop_reason: :tool_use), response("done")),
      tools: [exclusive_tool, child_tool],
      run:
    )

    result = parent.call("go")

    assert_equal "done", result.text
  ensure
    parent&.close
  end

  def test_last_prompt_declaration_wins
    agent_class = Class.new(LittleGhost::Agent)
    agent_class.system_prompt { "dynamic" }
    agent_class.system_prompt "static"
    assert_equal "static", agent_class.system_prompt

    agent_class.system_template "agents/example/system"
    assert_equal "static", agent_class.system_prompt
    assert_equal "agents/example/system", agent_class.system_template
  end

  def test_agent_callbacks_are_configured_once_on_the_class
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops
    end
    callbacks = agent_class.callbacks
    before = callbacks.instance_variable_get(:@callbacks).transform_values(&:length)

    agent_class.new(model: ScriptedModel.new(response("one")))
    agent_class.new(model: ScriptedModel.new(response("two")))

    assert_equal before, agent_class.callbacks.instance_variable_get(:@callbacks).transform_values(&:length)
  end

  def test_agent_callback_helpers_accept_blocks
    agent_class = Class.new(LittleGhost::Agent) do
      before_tool { LittleGhost::Support::Callbacks.cancel("blocked") }
    end
    agent = agent_class.new(model: ScriptedModel.new(response("done")))

    decision = agent.send(:run_callbacks, :before_tool, {})

    assert decision.cancel?
    assert_equal "blocked", decision.reason
  end

  def test_class_level_tools_reject_shared_instances
    tool_class = LittleGhost::Tool.define(name: "stateful", description: "Stateful") { "done" }

    error = assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) { tools tool_class.new }
    end

    assert_includes error.message, "use a block"
  end

  def test_class_tool_blocks_run_against_each_agent_without_changing_injected_resolvers
    tool_class = LittleGhost::Tool.define(name: "dynamic", description: "Dynamic") { "done" }
    class_receiver = nil
    injected_receiver = nil
    agent_class = Class.new(LittleGhost::Agent) do
      tools do
        class_receiver = self
        tool_class
      end
    end
    injected = lambda do
      injected_receiver = self
      []
    end

    agent = agent_class.new(model: Object.new, tools: [injected])

    assert_same agent, class_receiver
    assert_same self, injected_receiver
  ensure
    agent&.close
  end

  def test_standard_agent_includes_dormant_capability_mixins
    agent_class = Class.new(LittleGhost::Agent)
    agent = agent_class.new(model: ScriptedModel.new(response("done")))

    assert_includes agent_class.ancestors, LittleGhost::Agent::Skills
    assert_includes agent_class.ancestors, LittleGhost::Agent::ToolLoop
    assert_includes agent_class.ancestors, LittleGhost::Agent::ToolResultOffloading
    assert_includes agent_class.ancestors, LittleGhost::Agent::Delegation
    assert_empty agent.tool_registry.names
    assert_instance_of LittleGhost::Support::Callbacks, agent.class.callbacks
    assert LittleGhost::Agent.const_defined?(:UNSET, false)
  ensure
    agent&.close
  end

  def test_a_capability_mixin_can_be_included_directly_without_installing_twice
    agent_class = Class.new(LittleGhost::Agent) do
      include LittleGhost::Agent::ToolResultOffloading

      offload_large_tool_results
    end

    agent = agent_class.new(model: ScriptedModel.new(response("done")))

    assert_equal ["retrieve_offloaded_content"], agent.tool_registry.names
  ensure
    agent&.close
  end

  def test_callbacks_added_to_a_parent_are_visible_to_existing_subclasses
    parent = Class.new(LittleGhost::Agent)
    child = Class.new(parent)
    parent.before_model { LittleGhost::Support::Callbacks.cancel("blocked") }
    agent = child.new(model: ScriptedModel.new(response("done")))

    decision = agent.send(:run_callbacks, :before_model, {})

    assert decision.cancel?
    assert_equal "blocked", decision.reason
  end

  def test_capabilities_added_to_a_parent_are_visible_to_existing_subclasses
    parent = Class.new(LittleGhost::Agent)
    child = Class.new(parent)
    parent.offload_large_tool_results

    agent = child.new(model: Object.new)

    assert_equal ["retrieve_offloaded_content"], agent.tools.names
  ensure
    agent&.close
  end

  def test_child_capability_overrides_survive_later_parent_reconfiguration
    parent = Class.new(LittleGhost::Agent) { offload_large_tool_results max_chars: 10 }
    child = Class.new(parent) { offload_large_tool_results max_chars: 20 }
    parent.offload_large_tool_results max_chars: 30

    agent = child.new(model: Object.new)

    assert_equal ["retrieve_offloaded_content"], agent.tools.names
    assert_equal 20, child.tool_result_offloading_configuration.fetch(:max_chars)
  ensure
    agent&.close
  end

  def test_after_initialize_callbacks_use_the_agent_instance
    agent_class = Class.new(LittleGhost::Agent) do
      attr_reader :initialized_agent

      after_initialize { @initialized_agent = self }
    end
    agent = agent_class.new(model: ScriptedModel.new(response("done")))

    assert_same agent, agent.initialized_agent
  ensure
    agent&.close
  end

  def test_tool_loop_mixin_normalizes_excluded_tools_and_is_inherited
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "search"
      description "Search"
    end
    parent = Class.new(LittleGhost::Agent) do
      detect_tool_loops except: [tool_class, :status]
    end
    child = Class.new(parent)

    assert_equal %w[search status], parent.tool_loop_configuration.fetch(:except)
    assert_equal parent.tool_loop_configuration, child.tool_loop_configuration
    assert_same parent.tool_loop_configuration, child.tool_loop_configuration
    assert_predicate child.tool_loop_configuration, :frozen?
  end

  def test_inherited_mixin_configuration_is_immutable
    delegated = Class.new(LittleGhost::Agent)
    parent = Class.new(LittleGhost::Agent) do
      subagent delegated, tools: []
    end
    child = Class.new(parent)

    assert_raises(FrozenError) do
      child.subagent_declarations.first.fetch(:tools) << :unexpected
    end

    assert_empty parent.subagent_declarations.first.fetch(:tools)
    assert_empty child.subagent_declarations.first.fetch(:tools)
  end

  def test_inherited_agent_policy_is_deeply_immutable
    delegated = Class.new(LittleGhost::Agent) do
      agent_id "delegate"
      description "Delegated agent"
    end
    tool = Class.new(LittleGhost::Tool)
    parent = Class.new(LittleGhost::Agent) do
      system_prompt "Follow policy"
      tools [[tool]]
      skills paths: "trusted"
      detect_tool_loops except: :safe
      subagent delegated, tools: [[tool]]
    end
    child = Class.new(parent)
    declaration = child.subagent_declarations.first

    assert_raises(FrozenError) { child.system_prompt << " changed" }
    assert_raises(FrozenError) { child.tool_declarations.first << tool }
    assert_raises(FrozenError) { child.skills_configuration.fetch(:paths) << "/other" }
    assert_raises(FrozenError) { child.tool_loop_configuration.fetch(:except).first.replace("dangerous") }
    assert_raises(FrozenError) { declaration.fetch(:tools).first << tool }
    assert_raises(FrozenError) { declaration.fetch(:kind) << "-mutated" }
    assert_raises(FrozenError) { declaration.fetch(:description) << " changed" }
    assert_equal "Follow policy", parent.system_prompt
    assert_equal "delegate", delegated.agent_id
    assert_equal "Delegated agent", delegated.description
  end

  def test_named_features_install_their_tools_and_prompt_content
    Dir.mktmpdir do |root|
      path = File.join(root, "inspect", "SKILL.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~SKILL)
        ---
        name: inspect
        description: Inspect the project
        ---
        Read the code carefully.
      SKILL
      run = nil
      agent_class = Class.new(LittleGhost::Agent) do
        system_prompt "Base instructions"
        tools LittleGhost::Tools::WriteTodos
        skills paths: lambda { |current_run|
          raise "wrong run" unless current_run.nil?

          [root]
        }
        detect_tool_loops
        offload_large_tool_results
      end
      model = ScriptedModel.new(response("done"))
      agent = agent_class.new(model:, run:)

      assert_equal %w[write_todos retrieve_offloaded_content skills].sort, agent.tool_registry.names.sort
      assert_includes agent.prompt_locals.fetch(:skills_prompt), "inspect"
      decision = agent.send(
        :include_skills_prompt,
        {messages: [LittleGhost::Message.new(role: :system, content: "Base instructions")]}
      )
      prompt = decision.value.fetch(:messages).first.text
      assert_includes prompt, "<available_skills>"
      assert_includes prompt, "<name>inspect</name>"

      agent.call("Inspect this")
      system_message = model.requests.first.messages.first
      assert_equal :system, system_message.role
      assert_includes system_message.text, "<available_skills>"
      assert_includes system_message.text, "<name>inspect</name>"
    ensure
      agent&.close
    end
  end

  def test_closes_per_run_tools_once
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "closable"
      description "Close me"
      attr_reader :closes

      def initialize(...)
        super
        @closes = 0
      end

      def call(_input, context:) = "ok"
      def close = @closes += 1
    end
    agent = LittleGhost::Agent.new(model: ScriptedModel.new(response("done")), tools: [tool_class])
    tool = agent.tool_registry.fetch("closable")

    agent.close
    agent.close

    assert_equal 1, tool.closes
  end

  def test_rejects_duplicate_tools_and_closes_both_instances
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "duplicate"
      description "Duplicate tool"
      attr_reader :closes

      def initialize(...)
        super
        @closes = 0
      end

      def close = @closes += 1
    end
    selected = tool_class.new
    rejected = tool_class.new
    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::Agent.new(
        model: ScriptedModel.new(response("done")),
        tools: [selected, rejected]
      )
    end

    assert_equal 1, selected.closes
    assert_equal 1, rejected.closes
  end

  def test_closes_tools_constructed_before_a_later_constructor_fails
    closable = Class.new(LittleGhost::Tool) do
      tool_name "closable_constructor"
      description "Construct successfully"

      class << self
        attr_accessor :closes
      end

      def close = self.class.closes = self.class.closes.to_i + 1
    end
    failing = Class.new(LittleGhost::Tool) do
      tool_name "failing_constructor"
      description "Fail construction"

      def initialize(...) = raise("constructor failed")
    end

    error = assert_raises(RuntimeError) do
      LittleGhost::Agent.new(
        model: ScriptedModel.new(response("done")),
        tools: [closable, failing]
      )
    end

    assert_equal "constructor failed", error.message
    assert_equal 1, closable.closes
  end

  def test_closes_input_tools_when_a_feature_fails_before_registry_creation
    tool = Class.new(LittleGhost::Tool) do
      tool_name "feature_failure"
      description "Close on feature failure"
      attr_reader :closes

      def initialize(...)
        super
        @closes = 0
      end

      def close = @closes += 1
    end.new
    agent_class = Class.new(LittleGhost::Agent) do
      skills paths: ["/path/that/does/not/exist"]
    end

    assert_raises(Errno::ENOENT) do
      agent_class.new(model: ScriptedModel.new(response("done")), tools: [tool])
    end

    assert_equal 1, tool.closes
  end

  def test_serializes_a_batch_containing_exclusive_tools
    tracker = Struct.new(:active, :maximum, :mutex).new(0, 0, Mutex.new)
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "exclusive"
      description "Mutate shared state"
      exclusive true

      define_method(:initialize) do |tracker:, **options|
        super(**options)
        @tracker = tracker
      end

      define_method(:call) do |_input, context:|
        @tracker.mutex.synchronize do
          @tracker.active += 1
          @tracker.maximum = [@tracker.maximum, @tracker.active].max
        end
        sleep(0.01)
        "ok"
      ensure
        @tracker.mutex.synchronize { @tracker.active -= 1 }
      end
    end
    uses = 2.times.map { |index| LittleGhost::Content::ToolUse.new(id: "call-#{index}", name: "exclusive", input: {}) }
    model = ScriptedModel.new(response(uses, stop_reason: :tool_use), response("done"))
    tools = [tool_class.new(tracker:)]

    LittleGhost::Agent.new(model:, tools:).call("go")

    assert_equal 1, tracker.maximum
  end

  def test_exclusive_tools_share_the_run_lock_across_agents
    tracker = Struct.new(:active, :maximum, :mutex).new(0, 0, Mutex.new)
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "shared_mutation"
      description "Mutate shared run state"
      exclusive true

      define_method(:initialize) do |tracker:, **options|
        super(**options)
        @tracker = tracker
      end

      define_method(:call) do |_input, context:|
        @tracker.mutex.synchronize do
          @tracker.active += 1
          @tracker.maximum = [@tracker.maximum, @tracker.active].max
        end
        sleep(0.01)
        "ok"
      ensure
        @tracker.mutex.synchronize { @tracker.active -= 1 }
      end
    end
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "go"),
      application: Object.new
    )
    agent_class = Class.new(LittleGhost::Agent) { system_prompt "" }
    agents = 2.times.map do |index|
      use = LittleGhost::Content::ToolUse.new(id: "call-#{index}", name: "shared_mutation", input: {})
      model = ScriptedModel.new(response([use], stop_reason: :tool_use), response("done"))
      agent_class.new(model:, tools: [tool_class.new(tracker:, run:)], run:)
    end

    agents.map { |agent| Thread.new { agent.call("go") } }.each(&:join)

    assert_equal 1, tracker.maximum
  end

  private

  def response(content, stop_reason: :end_turn, usage: LittleGhost::Usage.new)
    message = LittleGhost::Message.new(role: :assistant, content: content)
    LittleGhost::ModelResponse.new(message: message, stop_reason: stop_reason, usage: usage)
  end
end
