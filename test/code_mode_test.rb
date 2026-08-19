# frozen_string_literal: true

require "test_helper"

class CodeModeTest < Minitest::Test
  CapabilitySandbox = Data.define(:capabilities)

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
      events = [LittleGhost::StreamEvent.build(:message_start)]
      response.message.content.grep(LittleGhost::Content::ToolUse).each_with_index do |use, index|
        events << LittleGhost::StreamEvent.build(:tool_call_start, index:, id: use.id, name: use.name)
        events << LittleGhost::StreamEvent.build(:tool_call_delta, index:, arguments: JSON.generate(use.input))
        events << LittleGhost::StreamEvent.build(:tool_call_stop, index:, tool_use: use)
      end
      events << LittleGhost::StreamEvent.build(:message_stop, response:)
      events.each
    end
  end

  class AgentEngine < LittleGhost::CodeMode::Engine
    attr_reader :sessions

    def initialize
      @sessions = []
    end

    def language = :test
    def instructions(catalog:) = "Test code mode with #{catalog.length} tools."

    def open_session(broker:, sandbox_factory:, limits:)
      AgentSession.new(broker:).tap { |session| sessions << session }
    end
  end

  class AgentSession < LittleGhost::CodeMode::Session
    attr_reader :results, :sources

    def initialize(broker:)
      @broker = broker
      @results = []
      @sources = []
      @closed = false
    end

    def execute(source:, catalog:, context:, **)
      sources << source
      Integer(source).times do |index|
        results << @broker.call("nested", {"value" => "same"}, id: "nested-#{index}")
      end
      LittleGhost::CodeMode::ProgramResult.new(output: results.map(&:value).join("\n"))
    end

    def close = @closed = true
    def closed? = @closed
  end

  class BlockingCloseAgentEngine < AgentEngine
    def open_session(broker:, **)
      BlockingCloseAgentSession.new(broker:).tap { |session| sessions << session }
    end
  end

  class BlockingCloseAgentSession < AgentSession
    attr_reader :close_entered, :close_release
    attr_accessor :close_error

    def initialize(**)
      super
      @close_entered = Queue.new
      @close_release = Queue.new
    end

    def close
      close_entered << true
      close_release.pop
      raise close_error if close_error

      super
    end
  end

  class DefaultOptionsEngine < LittleGhost::CodeMode::Engine
    attr_reader :session

    def language = :test
    def instructions(catalog:) = "Test defaults."

    def open_session(**)
      @session = DefaultOptionsSession.new
    end
  end

  class DefaultOptionsSession < LittleGhost::CodeMode::Session
    attr_reader :execute_options, :wait_options, :stop_options

    def execute(source:, catalog:, context:, max_output_tokens: :default)
      @execute_options = {max_output_tokens:}
      LittleGhost::CodeMode::ProgramResult.new(status: :still_working)
    end

    def wait(context:, max_output_tokens: :default)
      @wait_options = {max_output_tokens:}
      LittleGhost::CodeMode::ProgramResult.new
    end

    def stop(context:, max_output_tokens: :default)
      @stop_options = {max_output_tokens:}
      LittleGhost::CodeMode::ProgramResult.new(status: :terminated)
    end
  end

  class SerialEngine < LittleGhost::CodeMode::Engine
    attr_reader :session

    def language = :test
    def instructions(catalog:) = "Test serialization."

    def open_session(**)
      @session ||= SerialSession.new
    end
  end

  class SerialSession < LittleGhost::CodeMode::Session
    attr_reader :max_active

    def initialize
      @mutex = Mutex.new
      @active = 0
      @max_active = 0
    end

    def execute(**)
      @mutex.synchronize do
        @active += 1
        @max_active = [@max_active, @active].max
      end
      sleep 0.05
      LittleGhost::CodeMode::ProgramResult.new
    ensure
      @mutex.synchronize { @active -= 1 }
    end

    def close = nil
  end

  class BlockingEngine < LittleGhost::CodeMode::Engine
    attr_reader :session

    def language = :test
    def instructions(catalog:) = "Test close races."

    def open_session(**)
      @session ||= BlockingSession.new
    end
  end

  class DeferredBrokerEngine < AgentEngine
    def open_session(broker:, **)
      DeferredBrokerSession.new(broker:).tap { |session| sessions << session }
    end
  end

  class DeferredBrokerSession < LittleGhost::CodeMode::Session
    def initialize(broker:)
      @broker = broker
    end

    def execute(**)
      LittleGhost::CodeMode::ProgramResult.new(status: :still_working)
    end

    def call_nested
      @broker.call("nested", {"value" => "same"}, id: "nested-later")
    end
  end

  class BlockingSession < LittleGhost::CodeMode::Session
    attr_reader :entered, :release

    def initialize
      @entered = Queue.new
      @release = Queue.new
      @closed = false
    end

    def execute(**)
      entered << true
      release.pop
      LittleGhost::CodeMode::ProgramResult.new
    end

    def close = @closed = true
    def closed? = @closed
  end

  def test_engine_registration_accepts_only_engine_classes_and_instances
    name = :registration_contract_test

    assert_same AgentEngine, LittleGhost::CodeMode.register_engine(name, AgentEngine)
    assert_same AgentEngine, LittleGhost::CodeMode.resolve_engine(name)
    assert_raises(ArgumentError) { LittleGhost::CodeMode.register_engine(name, -> { AgentEngine.new }) }
    assert_raises(ArgumentError) { LittleGhost::CodeMode.resolve_engine(Object.new) }
  ensure
    LittleGhost::CodeMode.engines.delete(name)
  end

  def test_engine_requires_owned_subprocesses_or_enforced_denial
    engine = AgentEngine.new
    owned = LittleGhost::Sandbox::Capabilities.new(features: [:process_tree_ownership])
    denied = LittleGhost::Sandbox::Capabilities.new(features: [:process_spawn_denial])
    ambiguous = LittleGhost::Sandbox::Capabilities.new(features: [:process_spawn], isolation: :seatbelt)

    assert engine.send(:allow_subprocesses_for, CapabilitySandbox.new(owned))
    refute engine.send(:allow_subprocesses_for, CapabilitySandbox.new(denied))
    assert_raises(LittleGhost::CapabilityError) do
      engine.send(:allow_subprocesses_for, CapabilitySandbox.new(ambiguous))
    end
  end

  def test_ruby_engine_rejects_unsupported_limits
    error = assert_raises(ArgumentError) do
      LittleGhost::CodeMode::RubyEngine.new.open_session(
        broker: Object.new,
        sandbox_factory: Object.new,
        limits: {processes: 8}
      )
    end

    assert_includes error.message, ":processes"
  end

  def test_ruby_engine_brokers_tools_and_returns_the_final_expression
    calls = []
    tool = LittleGhost::Tool.define(
      name: "add-values",
      description: "Add two values.",
      input_schema: {type: "object"}
    ) do |input|
      calls << input
      input.fetch("left") + input.fetch("right")
    end
    registry = LittleGhost::ToolRegistry.new([tool])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    result = session.execute(
      source: "text(tools.add_values(left: 2, right: 3)); 9",
      catalog: broker.catalog
    )

    assert_equal "5", result.output
    assert_equal 9, result.value
    assert_predicate result, :completed?
    assert_equal [{"left" => 2, "right" => 3}], calls
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_engine_returns_non_ascii_tool_results_across_binary_frames
    template = {type: "result", id: "call-1", value: "—", error: nil}
    value = "—#{"a" * (128 - JSON.generate(template).bytesize)}"
    tool = LittleGhost::Tool.define(name: "diagnostic", description: "Return diagnostic text.") { value }
    registry = LittleGhost::ToolRegistry.new([tool])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    result = session.execute(source: "tools.diagnostic", catalog: broker.catalog)

    assert_equal 128, JSON.generate(template.merge(value:)).bytesize
    assert_equal value, result.value
  ensure
    session&.close
    registry&.close
  end

  def test_each_ruby_program_gets_fresh_process_state
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    assert_equal 1, session.execute(source: "$code_mode_state = 1", catalog: []).value
    assert_nil session.execute(source: "$code_mode_state", catalog: []).value
  ensure
    session&.close
    registry&.close
  end

  def test_wait_observes_the_same_program_and_returns_incremental_output
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.1)

    first = session.execute(source: 'text("before"); sleep(0.2); text("after"); 4', catalog: [])
    observations = [first]
    observations << session.wait while observations.last.still_working?
    completed = observations.last

    assert_predicate first, :still_working?
    assert_equal "before", first.output
    assert_equal "after", observations.drop(1).map(&:output).join
    assert_equal 4, completed.value
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_engine_normalizes_invalid_stderr_before_returning_output
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    result = session.execute(source: 'STDERR.write([255].pack("C")); 1', catalog: [])

    assert_equal :completed, result.status
    assert_equal "�", result.output
    assert_predicate result.output, :valid_encoding?
    JSON.generate(output: result.output)
  ensure
    session&.close
    registry&.close
  end

  def test_observation_timeout_does_not_pause_the_program
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.001)

    running = session.execute(source: "sleep(0.02); 7", catalog: [])
    completed = running
    completed = session.wait while completed.still_working?

    assert_equal :still_working, running.status
    assert_equal 7, completed.value
  ensure
    session&.close
    registry&.close
  end

  def test_rejected_exec_does_not_close_the_active_program
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.001)

    running = session.execute(source: "sleep(0.02); 7", catalog: [])

    assert_equal :still_working, running.status
    assert_raises(LittleGhost::ToolError) { session.execute(source: "8", catalog: []) }
    result = running
    result = session.wait while result.still_working?
    assert_equal 7, result.value
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_program_deadline_cleans_an_unobserved_program
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, wall_seconds: 0.05, observation_seconds: 0.01)

    first = session.execute(source: "sleep 30", catalog: [])
    Timeout.timeout(2) { sleep(0.001) until session.instance_variable_get(:@session).nil? }
    error = assert_raises(LittleGhost::ToolError) { session.wait }

    assert_predicate first, :still_working?
    assert_includes error.message, "timed out"
    assert_nil session.instance_variable_get(:@sandbox)
    assert_nil session.instance_variable_get(:@workspace)
  ensure
    session&.close
    registry&.close
  end

  def test_except_tools_remain_model_facing_and_are_excluded_from_broker_catalog
    exception = LittleGhost::Tool.define(name: "confirm", description: "Confirm.") { "yes" }
    coded = LittleGhost::Tool.define(name: "lookup", description: "Look up.") { "value" }
    registry = LittleGhost::ToolRegistry.new([exception, coded])
    broker = LittleGhost::CodeMode::Broker.new(registry:, except: ["confirm"])

    assert_equal ["lookup"], broker.catalog.map { |tool| tool.fetch(:name) }
    assert broker.call("lookup").error.nil?
    assert_match(/not available/, broker.call("confirm").error)
  ensure
    registry&.close
  end

  def test_framework_subagent_controls_stay_top_level_and_outside_the_broker
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { "value" }
    manager = LittleGhost::Subagents::Manager.new([])
    controls = manager.tools
    model = ScriptedModel.new(response("done"))
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    agent = agent_class.new(model:, tools: [nested, *controls])

    assert_equal "done", agent.call("go").text
    assert_equal(
      %w[exec interject_subagent list_subagents send_message_to_subagent spawn_subagent stop wait wait_for_subagents],
      model.requests.first.tools.map { |tool| tool.fetch(:name) }.sort
    )
    assert_equal ["nested"], agent.code_mode_runtime.catalog.map { |tool| tool.fetch(:name) }
  ensure
    agent&.close
  end

  def test_broker_preserves_call_results_from_a_custom_dispatcher
    tool = LittleGhost::Tool.define(name: "lookup", description: "Look up.") { "unused" }
    registry = LittleGhost::ToolRegistry.new([tool])
    expected = LittleGhost::CodeMode::CallResult.new(id: "call-1", value: {"ok" => true}, error: nil)
    broker = LittleGhost::CodeMode::Broker.new(
      registry:,
      dispatch: ->(_call) { expected }
    )

    assert_same expected, broker.call("lookup", {}, id: "call-1")
  ensure
    registry&.close
  end

  def test_engine_rejects_normalized_and_reserved_method_collisions
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)
    duplicate = [{name: "same-name"}, {name: "same_name"}]

    assert_raises(LittleGhost::ConfigurationError) do
      session.execute(source: "nil", catalog: duplicate)
    end
    assert_raises(LittleGhost::ConfigurationError) do
      session.execute(source: "nil", catalog: [{name: "parallel"}])
    end
  ensure
    session&.close
    registry&.close
  end

  def test_parallel_tool_calls_overlap_in_the_parent_broker
    mutex = Mutex.new
    condition = ConditionVariable.new
    entered = 0
    tool = LittleGhost::Tool.define(name: "barrier", description: "Wait for peer.") do |input|
      mutex.synchronize do
        entered += 1
        condition.broadcast if entered == 2
        condition.wait(mutex, 1) while entered < 2
      end
      input.fetch("value")
    end
    registry = LittleGhost::ToolRegistry.new([tool])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    result = session.execute(
      source: "tools.parallel(-> { tools.barrier(value: 1) }, -> { tools.barrier(value: 2) })",
      catalog: broker.catalog
    )

    assert_equal [1, 2], result.value
    assert_equal 2, entered
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_instructions_render_typed_tool_signatures
    catalog = [{
      name: "find-items",
      description: "Find matching items.",
      input_schema: {
        "type" => "object",
        "properties" => {
          "query" => {"type" => "string", "minLength" => 2, "description" => "Search text."},
          "status" => {"type" => "string", "enum" => %w[open closed]},
          "filters" => {
            "type" => "object",
            "properties" => {"ids" => {"type" => "array", "items" => {"type" => "integer"}}}
          }
        },
        "required" => ["query"]
      },
      output_schema: {"type" => "array", "items" => {"type" => "object"}}
    }]

    instructions = LittleGhost::CodeMode::RubyEngine.new.instructions(catalog:)

    refute_includes LittleGhost::CodeMode::RubyEngine::DEFAULT_LIMITS, :processes
    assert_includes instructions, "Find matching items."
    assert_includes instructions, "tools.find_items(query:, status: nil, filters: nil)"
    assert_includes instructions, "# @param query [String] required; Search text. (minLength=2)"
    assert_includes instructions, '# @param status ["open" | "closed"] optional'
    assert_includes instructions, "# @param filters [{ids: Array[Integer]}] optional"
    assert_includes instructions, "# @return [Array[Hash[String, untyped]]]"
    assert_includes instructions, "ALL_TOOLS"
    assert_includes instructions, "fresh program in a new Ruby process"
    assert_includes instructions, "do not persist between exec calls"
    assert_includes instructions, "If exec or wait returns `still_working`, call wait"
    assert_includes instructions, "Do not call wait or stop after `completed`, `error`, or"
    assert_includes instructions, "Sandbox controls filesystem, network, subprocess, and optional-library"
    assert_includes instructions, "JSON results become ordinary Ruby values"
    assert_includes instructions, "callable order"
    refute_includes instructions, "FRAME"
    assert_includes instructions, "final Ruby expression becomes the completed program value"
    refute_includes instructions, "yield_control"
  end

  def test_ruby_engine_enforces_source_output_program_and_tool_call_limits
    tool = LittleGhost::Tool.define(name: "echo", description: "Echo.") { |input| input }
    registry = LittleGhost::ToolRegistry.new([tool])
    broker = LittleGhost::CodeMode::Broker.new(registry:)

    session = ruby_session(broker:, source_bytes: 3)
    assert_raises(LittleGhost::ToolError) { session.execute(source: "1234", catalog: broker.catalog) }
    session.close

    session = ruby_session(broker:, output_bytes: 3)
    assert_raises(LittleGhost::ToolError) { session.execute(source: 'text("1234")', catalog: broker.catalog) }
    session.close

    session = ruby_session(broker:, programs: 1)
    assert_equal 1, session.execute(source: "1", catalog: broker.catalog).value
    assert_raises(LittleGhost::ToolError) { session.execute(source: "2", catalog: broker.catalog) }
    session.close

    session = ruby_session(broker:, tool_calls: 1)
    result = session.execute(source: "tools.echo; tools.echo", catalog: broker.catalog)
    assert_equal :error, result.status
    assert_match(/tool call limit/, result.error)
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_engine_rejects_child_stdout_outside_the_protocol
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)

    assert_raises(LittleGhost::ProtocolError) do
      session.execute(source: 'STDOUT.puts("hostile"); nil', catalog: [])
    end
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_engine_cleans_owned_resources_after_nested_tool_failure
    tool = LittleGhost::Tool.define(name: "fail", description: "Fail.") { "unused" }
    registry = LittleGhost::ToolRegistry.new([tool])
    entered = Queue.new
    broker = LittleGhost::CodeMode::Broker.new(
      registry:,
      dispatch: lambda do |_call|
        entered << true
        raise "nested failure"
      end
    )
    sandbox = nil
    directory = nil
    sandbox_class = Class.new(LittleGhost::Sandboxes::Unrestricted) do
      attr_reader :closed

      def close
        @closed = true
        super
      end
    end
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      directory = workspace.root
      sandbox = sandbox_class.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :inherit}
      )
    end
    session = LittleGhost::CodeMode::RubyEngine.new.open_session(
      broker:, sandbox_factory: factory,
      limits: {memory_bytes: 128 * 1024 * 1024, cleanup_seconds: 0.1}
    )

    error = assert_raises(RuntimeError) do
      session.execute(source: "tools.fail", catalog: broker.catalog)
    end

    Timeout.timeout(5) { entered.pop }
    assert_equal "nested failure", error.message
    assert sandbox.closed
    refute File.exist?(directory)
  ensure
    begin
      session&.close
    rescue RuntimeError
      nil
    end
    registry&.close
  end

  def test_ruby_engine_cannot_be_reused_after_nested_tool_cleanup_times_out
    tool = LittleGhost::Tool.define(name: "slow", description: "Wait.") { "unused" }
    registry = LittleGhost::ToolRegistry.new([tool])
    entered = Queue.new
    release = Queue.new
    finished = Queue.new
    broker = LittleGhost::CodeMode::Broker.new(
      registry:,
      dispatch: lambda do |_call|
        entered << true
        release.pop
        raise "old program failure"
      ensure
        finished << true
      end
    )
    session = ruby_session(broker:, cleanup_seconds: 0.01, observation_seconds: 0.1)

    running = session.execute(source: "tools.slow", catalog: broker.catalog)
    Timeout.timeout(5) { entered.pop }

    assert_equal :still_working, running.status
    assert_raises(LittleGhost::CleanupError) { session.stop }
    release << true
    Timeout.timeout(5) { finished.pop }
    assert_raises(LittleGhost::ToolError) { session.execute(source: "42", catalog: []) }
  ensure
    release << true if release && release.empty?
    begin
      session&.close
    rescue RuntimeError
      nil
    end
    registry&.close
  end

  def test_ruby_termination_ignores_a_late_reply_to_the_closed_process
    tool = LittleGhost::Tool.define(name: "slow", description: "Wait.") { "unused" }
    registry = LittleGhost::ToolRegistry.new([tool])
    entered = Queue.new
    release = Queue.new
    broker = LittleGhost::CodeMode::Broker.new(
      registry:,
      dispatch: lambda do |call|
        entered << true
        release.pop
        LittleGhost::CodeMode::CallResult.new(id: call.id, value: "late", error: nil)
      end
    )
    session = ruby_session(broker:, cleanup_seconds: 1, observation_seconds: 0.1)
    running = session.execute(source: "tools.slow", catalog: broker.catalog)
    Timeout.timeout(15) { entered.pop }
    releaser = Thread.new do
      sleep(0.05)
      release << true
    end

    terminated = session.stop

    assert_equal :still_working, running.status
    assert_equal :terminated, terminated.status
    releaser.join
  ensure
    release << true if release && release.empty?
    releaser&.join(1)
    session&.close
    registry&.close
  end

  def test_ruby_engine_closes_a_partially_started_program_when_the_initial_frame_fails
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    sandboxes = []
    sandbox_class = Class.new(LittleGhost::Sandboxes::Unrestricted) do
      attr_reader :closed

      def close
        @closed = true
        super
      end
    end
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      sandbox_class.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :inherit}
      ).tap { |sandbox| sandboxes << sandbox }
    end
    session = LittleGhost::CodeMode::RubyEngine.new.open_session(
      broker:, sandbox_factory: factory,
      limits: {memory_bytes: 128 * 1024 * 1024}
    )

    LittleGhost::CodeMode::Protocol.stub(:dump, ->(*) { raise LittleGhost::CodeMode::Protocol::Error, "invalid" }) do
      assert_raises(LittleGhost::CodeMode::Protocol::Error) do
        session.execute(source: "1", catalog: [])
      end
    end

    assert sandboxes.first.closed
    assert_equal 2, session.execute(source: "2", catalog: []).value
  ensure
    session&.close
    registry&.close
  end

  def test_stop_terminates_the_active_program_and_releases_the_process
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.01)

    running = session.execute(source: "sleep 30", catalog: [])
    terminated = session.stop

    assert_predicate running, :still_working?
    assert_equal :terminated, terminated.status
    assert_raises(LittleGhost::ToolError) { session.wait }
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_session_rejects_overlapping_direct_controls
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.05)
    assert_predicate session.execute(source: "sleep 30", catalog: []), :still_working?

    waiting = Thread.new { session.wait }
    control_mutex = session.instance_variable_get(:@control_mutex)
    Timeout.timeout(1) { Thread.pass until control_mutex.locked? }

    error = assert_raises(LittleGhost::ToolError) { session.stop }

    assert_includes error.message, "already active"
    assert_predicate waiting.value, :still_working?
    assert_equal :terminated, session.stop.status
  ensure
    waiting&.join
    session&.close
    registry&.close
  end

  def test_ruby_watchdog_finishes_cleanup_before_a_new_program_can_start
    entered = Queue.new
    release = Queue.new
    process_class = Class.new do
      attr_reader :closed

      def initialize(entered, release)
        @entered = entered
        @release = release
        @closed = false
      end

      def write(*) = nil

      def read(timeout:)
        sleep(timeout)
        LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: "", stderr: "", eof: false)
      end

      def terminate
        @entered << true
        @release.pop
      end

      def close = @closed = true
    end
    sandbox_class = Class.new do
      attr_reader :closed, :process

      def initialize(process)
        @process = process
        @closed = false
      end

      def open = self
      def start_program(*) = process
      def close = @closed = true
    end
    process = process_class.new(entered, release)
    sandboxes = []
    roots = []
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      roots << workspace.root
      sandbox_class.new(process).tap { |sandbox| sandboxes << sandbox }
    end
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    limits = LittleGhost::CodeMode::RubyEngine::DEFAULT_LIMITS.merge(
      memory_bytes: 128 * 1024 * 1024,
      wall_seconds: 0.03
    )
    session = LittleGhost::CodeMode::Ruby::Session.new(
      broker:, sandbox_factory: factory, subprocess_policy: ->(_sandbox) { true },
      limits:, observation_seconds: 0.005
    )
    assert_predicate session.execute(source: "sleep", catalog: []), :still_working?
    Timeout.timeout(1) { entered.pop }

    second = Thread.new do
      session.execute(source: "second", catalog: [])
    rescue => error
      error
    end
    sleep(0.01)

    assert second.alive?
    assert_equal 1, sandboxes.length
    release << true
    error = second.value
    assert_instance_of LittleGhost::ToolError, error
    assert_includes error.message, "timed out"
    assert_predicate process, :closed
    assert_predicate sandboxes.first, :closed
    refute File.exist?(roots.first)
  ensure
    release << true if release && release.empty?
    second&.join
    begin
      session&.close
    rescue LittleGhost::ToolError
      nil
    end
    registry&.close
  end

  def test_ruby_close_surfaces_an_unobserved_watchdog_cleanup_error
    close_entered = Queue.new
    close_release = Queue.new
    process_class = Class.new do
      def initialize(entered, release)
        @entered = entered
        @release = release
      end

      def write(*) = nil

      def read(timeout:)
        sleep(timeout)
        LittleGhost::Sandbox::ProcessSession::Chunk.new(stdout: "", stderr: "", eof: false)
      end

      def terminate = nil

      def close
        @entered << true
        @release.pop
        raise LittleGhost::CleanupError, "watchdog cleanup failed"
      end
    end
    sandbox_class = Class.new do
      def initialize(process) = @process = process
      def open = self
      def start_program(*) = @process
      def close = nil
    end
    process = process_class.new(close_entered, close_release)
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      sandbox_class.new(process)
    end
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    limits = LittleGhost::CodeMode::RubyEngine::DEFAULT_LIMITS.merge(wall_seconds: 0.03)
    session = LittleGhost::CodeMode::Ruby::Session.new(
      broker:, sandbox_factory: factory, subprocess_policy: ->(_sandbox) { true },
      limits:, observation_seconds: 0.005
    )
    assert_predicate session.execute(source: "sleep", catalog: []), :still_working?
    Timeout.timeout(1) { close_entered.pop }
    closing = Thread.new do
      session.close
    rescue => error
      error
    end
    sleep(0.01)

    assert closing.alive?
    close_release << true
    raised = closing.value

    assert_instance_of LittleGhost::CleanupError, raised
    assert_equal "watchdog cleanup failed", raised.message
  ensure
    close_release << true if close_release && close_release.empty?
    closing&.join
    begin
      session&.close
    rescue LittleGhost::CleanupError
      nil
    end
    registry&.close
  end

  def test_ruby_close_prevents_a_program_from_starting_after_the_factory_returns
    entered = Queue.new
    release = Queue.new
    sandbox_class = Class.new do
      attr_reader :closed, :starts

      def initialize
        @closed = false
        @starts = 0
      end

      def open = self

      def start_program(*)
        @starts += 1
        raise "program must not start"
      end

      def close = @closed = true
    end
    sandbox = sandbox_class.new
    root = nil
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      root = workspace.root
      entered << true
      release.pop
      sandbox
    end
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = LittleGhost::CodeMode::Ruby::Session.new(
      broker:, sandbox_factory: factory, subprocess_policy: ->(_sandbox) { true },
      limits: LittleGhost::CodeMode::RubyEngine::DEFAULT_LIMITS
    )
    execution = Thread.new do
      session.execute(source: "1", catalog: [])
    rescue => error
      error
    end
    Timeout.timeout(1) { entered.pop }

    close_error = assert_raises(LittleGhost::ToolError) { session.close }
    assert_includes close_error.message, "control operation is active"
    release << true

    execution_error = execution.value
    assert_instance_of LittleGhost::ToolError, execution_error
    assert_includes execution_error.message, "session is closed"
    assert_equal 0, sandbox.starts
    assert_predicate sandbox, :closed
    refute File.exist?(root)
    session.close
  ensure
    release << true if release && release.empty?
    execution&.join
    session&.close
    registry&.close
  end

  def test_ruby_termination_honors_the_requested_output_budget
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:, observation_seconds: 0.05)

    session.execute(source: 'sleep 0.1; text("abcdefghij"); sleep 30', catalog: [])
    sleep 0.15
    terminated = session.stop(max_output_tokens: 1)

    assert_equal :terminated, terminated.status
    assert_equal "ab…2 tokens truncated…ij", terminated.output
  ensure
    session&.close
    registry&.close
  end

  def test_ruby_termination_cleans_owned_resources_when_the_backend_raises
    registry = LittleGhost::ToolRegistry.new([])
    broker = LittleGhost::CodeMode::Broker.new(registry:)
    session = ruby_session(broker:)
    process = Object.new
    process.define_singleton_method(:terminate) { raise "termination failed" }
    process.define_singleton_method(:close) { @closed = true }
    process.define_singleton_method(:closed?) { @closed }
    resource_class = Class.new do
      attr_reader :closed

      def close
        @closed = true
      end
    end
    sandbox = resource_class.new
    workspace = resource_class.new
    directory = Dir.mktmpdir("little-ghost-termination-test-")
    session.instance_variable_set(:@session, process)
    session.instance_variable_set(:@sandbox, sandbox)
    session.instance_variable_set(:@workspace, workspace)
    session.instance_variable_set(:@workspace_directory, directory)
    session.instance_variable_set(:@generation, Object.new)

    error = assert_raises(RuntimeError) { session.stop }

    assert_equal "termination failed", error.message
    assert_predicate process, :closed?
    assert sandbox.closed
    assert workspace.closed
    refute File.exist?(directory)
    assert_nil session.instance_variable_get(:@session)
  ensure
    session&.close
    registry&.close
  end

  def test_agent_uses_one_tool_budget_for_model_facing_and_brokered_calls_while_excluding_exec
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    exception = LittleGhost::Tool.define(name: "confirm", description: "Confirm") { "done" }
    agent_class = Class.new(LittleGhost::Agent) do
      code_mode engine:, except: ["confirm"]
    end
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    confirm = LittleGhost::Content::ToolUse.new(id: "confirm-1", name: "confirm", input: {})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response([confirm], stop_reason: :tool_use))
    agent = agent_class.new(model:, tools: [nested, exception], max_tool_calls: 1)

    error = assert_raises(LittleGhost::ProtocolError) { agent.call("go") }

    assert_includes error.message, "maximum tool calls"
    assert_equal %w[confirm exec stop wait], model.requests.first.tools.map { |tool| tool.fetch(:name) }.sort
    assert_equal 1, engine.sessions.first.results.length
  ensure
    agent&.close
  end

  def test_brokered_exclusive_tool_does_not_deadlock_behind_exec
    engine = AgentEngine.new
    nested = Class.new(LittleGhost::Tool) do
      tool_name "nested"
      description "Nested"
      exclusive true

      def call(input) = input.fetch("value")
    end
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])

    assert_equal "done", agent.call("go").text
    assert_equal ["same"], engine.sessions.first.results.map(&:value)
  ensure
    agent&.close
  end

  def test_brokered_tool_cannot_reenter_code_mode_close
    engine = AgentEngine.new
    nested = Class.new(LittleGhost::Tool) do
      tool_name "nested"
      description "Nested"

      def call(_input)
        agent.code_mode_runtime.close(context:)
        "unexpected"
      end
    end
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])

    assert_equal "done", agent.call("go").text
    assert_match(/cannot close code mode/, engine.sessions.first.results.fetch(0).error)
    assert_predicate engine.sessions.first, :closed?
  ensure
    agent&.close
  end

  def test_external_close_waits_for_deferred_brokered_cleanup
    contexts = Queue.new
    engine = BlockingCloseAgentEngine.new
    nested = Class.new(LittleGhost::Tool) do
      tool_name "nested"
      description "Nested"

      define_method(:call) do |_input|
        contexts << context
        agent.code_mode_runtime.close(context:)
        "unexpected"
      end
    end
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])
    invocation = Thread.new { agent.call("go") }
    context = contexts.pop
    engine.sessions.first.close_entered.pop
    closing = Thread.new { agent.code_mode_runtime.close(context:) }

    refute closing.join(0.05), "external close returned before deferred session cleanup"
    engine.sessions.first.close_release << true

    assert_equal "done", invocation.value.text
    closing.value
    assert_predicate engine.sessions.first, :closed?
  ensure
    engine&.sessions&.first&.close_release&.push(true)
    invocation&.join
    closing&.join
    agent&.close
  end

  def test_external_close_observes_deferred_cleanup_failure
    contexts = Queue.new
    engine = BlockingCloseAgentEngine.new
    nested = Class.new(LittleGhost::Tool) do
      tool_name "nested"
      description "Nested"

      define_method(:call) do |_input|
        contexts << context
        agent.code_mode_runtime.close(context:)
        "unexpected"
      end
    end
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])
    invocation = Thread.new do
      agent.call("go")
    rescue => error
      error
    end
    context = contexts.pop
    engine.sessions.first.close_error = LittleGhost::CleanupError.new("cleanup failed")
    engine.sessions.first.close_entered.pop
    closing = Thread.new do
      agent.code_mode_runtime.close(context:)
    rescue => error
      error
    end
    refute closing.join(0.05), "external close returned before deferred session cleanup"
    engine.sessions.first.close_release << true

    invocation_error = invocation.value
    closing_error = closing.value

    assert_instance_of LittleGhost::CleanupError, invocation_error
    assert_instance_of LittleGhost::CleanupError, closing_error
    assert_equal "cleanup failed", invocation_error.message
    assert_equal "cleanup failed", closing_error.message
  ensure
    engine&.sessions&.first&.close_release&.push(true)
    invocation&.join
    closing&.join
    begin
      agent&.close
    rescue LittleGhost::CleanupError
      nil
    end
  end

  def test_batched_control_calls_preserve_model_order
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    controls = [
      LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"}),
      LittleGhost::Content::ToolUse.new(id: "exec-2", name: "exec", input: {"source" => "2"})
    ]
    model = ScriptedModel.new(response(controls, stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])

    assert_equal "done", agent.call("go").text
    assert_equal %w[1 2], engine.sessions.first.sources
  ensure
    agent&.close
  end

  def test_runtime_rejects_overlapping_control_calls_without_running_them_concurrently
    engine = SerialEngine.new
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    agent = agent_class.new(model: ScriptedModel.new)
    context = LittleGhost::RunContext.new

    threads = 2.times.map do
      Thread.new do
        agent.code_mode_runtime.execute(source: "1", context:)
        :completed
      rescue => error
        error
      end
    end
    results = threads.map(&:value)

    assert_equal 1, engine.session.max_active
    assert_equal 1, results.count(:completed)
    assert_equal 1, results.count { |result| result.is_a?(LittleGhost::ToolError) }
    assert_predicate LittleGhost::CodeMode::ExecTool, :exclusive
  ensure
    agent&.close
  end

  def test_close_prevents_same_context_state_resurrection
    engine = BlockingEngine.new
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    agent = agent_class.new(model: ScriptedModel.new)
    runtime = agent.code_mode_runtime
    context = LittleGhost::RunContext.new
    execution = Thread.new { runtime.execute(source: "1", context:) }
    Thread.pass until engine.session
    engine.session.entered.pop
    state = runtime.send(:existing_state, context)
    closing = Thread.new { runtime.close(context:) }
    Thread.pass until state.mutex.synchronize { state.closing }

    error = assert_raises(LittleGhost::ToolError) { runtime.execute(source: "2", context:) }
    engine.session.release << true
    execution.value
    closing.value

    assert_match(/clos/, error.message)
    assert_predicate engine.session, :closed?
  ensure
    2.times { engine&.session&.release&.push(true) }
    execution&.join
    closing&.join
    agent&.close
  end

  def test_exec_and_wait_preserve_engine_defaults_when_optional_arguments_are_omitted
    engine = DefaultOptionsEngine.new
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "yield"})
    wait = LittleGhost::Content::ToolUse.new(id: "wait-1", name: "wait", input: {})
    model = ScriptedModel.new(
      response([exec], stop_reason: :tool_use),
      response([wait], stop_reason: :tool_use),
      response("done")
    )
    agent = agent_class.new(model:)

    assert_equal "done", agent.call("go").text
    assert_equal({max_output_tokens: :default}, engine.session.execute_options)
    assert_equal({max_output_tokens: :default}, engine.session.wait_options)
  ensure
    agent&.close
  end

  def test_brokered_tools_keep_the_control_trace_context_after_the_control_returns
    carrier = {"traceparent" => "00-#{"1" * 32}-#{"2" * 16}-01"}
    telemetry = []
    tracing = TestInstrumentationSubscriber.new
    tracing.define_singleton_method(:trace_context) do |operation_id:|
      if operation_id == "control-operation"
        carrier
      else
        {}
      end
    end
    LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [tracing, TestTelemetryRecorder.new(telemetry)]
    )
    engine = DeferredBrokerEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    agent = agent_class.new(model: ScriptedModel.new, tools: [nested])
    execution = Struct.new(:operation_id, :parent_trace_context, :events)
      .new("control-operation", nil, [])

    LittleGhost::ExecutionState.with(tool_execution: execution) do
      agent.code_mode_runtime.execute(source: "1", context: LittleGhost::RunContext.new)
    end
    engine.sessions.first.call_nested

    nested_start = telemetry.find do |name, attributes|
      name == :tool_start && attributes[:tool_name] == "nested"
    end
    assert_equal carrier, nested_start.fetch(1).fetch(:trace_context)
  ensure
    agent&.close
  end

  def test_wait_tool_explains_the_active_program_state_machine
    specification = LittleGhost::CodeMode::WaitTool.specification

    assert_includes specification.fetch(:description), "exec or wait returned still_working"
    refute specification.dig(:input_schema, "properties").key?("terminate")
    refute specification.dig(:input_schema, "properties").key?("yield_time_ms")
    assert_includes LittleGhost::CodeMode::StopTool.specification.fetch(:description), "Stop the active"
  end

  def test_brokered_calls_participate_in_agent_tool_loop_detection
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    agent_class = Class.new(LittleGhost::Agent) do
      code_mode(engine:)
      detect_tool_loops warning_at: 2, terminate_at: 3
    end
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "2"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])

    assert_equal "done", agent.call("go").text
    assert_includes engine.sessions.first.results.last.value, LittleGhost::Agent::ToolLoop::WARNING
  ensure
    agent&.close
  end

  def test_code_mode_sessions_are_isolated_and_closed_between_invocations
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec_one = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    exec_two = LittleGhost::Content::ToolUse.new(id: "exec-2", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(
      response([exec_one], stop_reason: :tool_use), response("first"),
      response([exec_two], stop_reason: :tool_use), response("second")
    )
    agent = agent_class.new(model:, tools: [nested])

    assert_equal "first", agent.call("one").text
    assert_equal "second", agent.call("two").text
    assert_equal 2, engine.sessions.length
    assert engine.sessions.all?(&:closed?)
  ensure
    agent&.close
  end

  def test_brokered_calls_emit_normalized_model_and_execution_events
    engine = AgentEngine.new
    nested = LittleGhost::Tool.define(name: "nested", description: "Nested") { |input| input.fetch("value") }
    agent_class = Class.new(LittleGhost::Agent) { code_mode(engine:) }
    exec = LittleGhost::Content::ToolUse.new(id: "exec-1", name: "exec", input: {"source" => "1"})
    model = ScriptedModel.new(response([exec], stop_reason: :tool_use), response("done"))
    agent = agent_class.new(model:, tools: [nested])

    events = agent.stream("go").to_a
    start = events.index { |event| event.type == :tool_call_start && event.data[:name] == "nested" }
    visible_lifecycle = events.select do |event|
      %i[tool_call_start tool_call_delta tool_call_stop tool_start tool_stop].include?(event.type)
    end

    assert_equal %i[tool_call_start tool_call_delta tool_call_stop tool_start tool_stop],
      events.slice(start, 5).map(&:type)
    assert_equal %i[tool_call_start tool_call_delta tool_call_stop tool_start tool_stop], visible_lifecycle.map(&:type)
    assert_equal "nested", events.fetch(start + 2).data.fetch(:tool_use).name
    assert_equal "nested", events.fetch(start + 3).data.fetch(:tool_use).name
    assert_equal "nested", events.fetch(start + 4).data.fetch(:tool_use).name
    refute events.any? { |event| event.data[:name] == "exec" }
    refute events.any? { |event| event.data[:tool_use]&.name == "exec" }
  ensure
    agent&.close
  end

  private

  def response(content, stop_reason: :end_turn)
    message = LittleGhost::Message.new(role: :assistant, content:)
    LittleGhost::ModelResponse.new(message:, stop_reason:, usage: LittleGhost::Usage.new)
  end

  def ruby_session(broker:, **limits)
    observation_seconds = limits.delete(:observation_seconds) || LittleGhost::CodeMode::Ruby::Session::OBSERVATION_SECONDS
    factory = lambda do |workspace:, required_runtime_paths:|
      assert_empty required_runtime_paths
      LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :inherit}
      )
    end
    LittleGhost::CodeMode::Ruby::Session.new(
      broker:, sandbox_factory: factory,
      subprocess_policy: ->(_sandbox) { true },
      limits: LittleGhost::CodeMode::RubyEngine::DEFAULT_LIMITS.merge(
        memory_bytes: 128 * 1024 * 1024,
        **limits
      ),
      observation_seconds:
    )
  end
end
