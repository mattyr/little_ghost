# frozen_string_literal: true

require "test_helper"
require "json"
require "rbconfig"
require "timeout"
require "little_ghost/code_mode/javascript_engine"

class CodeModeEngineTest < Minitest::Test
  Result = Data.define(:id, :value, :error)

  class Broker
    DEFAULT_CATALOG = [{
      name: "echo-value",
      description: "Echo one value.",
      input_schema: {
        type: "object",
        properties: {value: {}},
        required: ["value"],
        additionalProperties: false
      }
    }].freeze

    attr_reader :catalog, :calls, :maximum_concurrency

    def initialize(catalog: DEFAULT_CATALOG, &behavior)
      @catalog = catalog
      @behavior = behavior
      @calls = []
      @active = 0
      @maximum_concurrency = 0
      @mutex = Mutex.new
    end

    def call(name, arguments, id:)
      @mutex.synchronize do
        @calls << [name, arguments, id]
        @active += 1
        @maximum_concurrency = [@maximum_concurrency, @active].max
      end
      return @behavior.call(name, arguments, id) if @behavior

      Result.new(id:, value: arguments.fetch("value"), error: nil)
    ensure
      @mutex.synchronize { @active -= 1 }
    end
  end

  class Sandbox
    attr_reader :processes

    def initialize(workspace)
      @workspace = workspace
      @processes = []
      @closed = false
    end

    def open = self

    def capabilities
      LittleGhost::Sandbox::Capabilities.new(
        features: %i[process_execute process_spawn],
        isolation: :none
      )
    end

    def start_program(command, cwd:, environment:, output_bytes:, memory_bytes:, cpu_seconds:, file_bytes:,
      allow_subprocesses:)
      LittleGhost::Sandbox::ProcessSession.new(
        command:,
        chdir: @workspace.resolve(cwd),
        environment:,
        output_bytes:,
        memory_bytes:,
        cpu_seconds:,
        file_bytes:
      ).tap { |process| @processes << process }
    end

    def close
      @closed = true
      processes.each(&:close)
    end

    def closed? = @closed
  end

  ContextError = Data.define(:error) do
    def check! = raise(error)
  end

  def setup
    @sessions = []
    @sandboxes = []
  end

  def teardown
    @sessions.reverse_each do |session|
      session.close
    rescue LittleGhost::CleanupError
      nil
    end
  end

  def test_exposes_javascript_instructions_from_the_little_ghost_catalog
    engine = LittleGhost::CodeMode::JavascriptEngine.new
    instructions = engine.instructions(catalog: Broker.new.catalog)

    assert_equal :javascript, engine.language
    refute_includes LittleGhost::CodeMode::JavascriptEngine::DEFAULT_LIMITS, :processes
    assert_includes instructions, "echo_value(args:"
    assert_includes instructions, "Promise<unknown>"
  end

  def test_rejects_unsupported_limits
    error = assert_raises(ArgumentError) do
      LittleGhost::CodeMode::JavascriptEngine.new.open_session(
        broker: Broker.new,
        sandbox_factory: ->(**) {},
        limits: {processes: 8}
      )
    end

    assert_includes error.message, ":processes"
  end

  def test_runs_the_v8_host_through_a_process_session_and_broker
    broker = Broker.new
    session = open_session(broker)
    result = execute(session, broker, 'text(await tools.echo_value({value: "hello"}));')

    assert_equal :completed, result.status
    assert_equal "hello", result.output
    assert_equal "echo-value", broker.calls.fetch(0).fetch(0)
    assert_kind_of LittleGhost::Sandbox::ProcessSession, @sandboxes.last.processes.first
  end

  def test_normalizes_canonical_names_and_protects_the_then_alias
    broker = Broker.new(catalog: [
      {name: "gateway___read-value", description: "Read", input_schema: {}},
      {name: "then", description: "Then", input_schema: {}}
    ]) do |name, _arguments, id|
      Result.new(id:, value: name, error: nil)
    end
    session = open_session(broker)
    result = execute(
      session,
      broker,
      "text(await tools.gateway___read_value({})); text(await tools._then({}));"
    )

    assert_equal "gateway___read-value\nthen", result.output
    assert_equal %w[gateway___read-value then], broker.calls.map(&:first)
  end

  def test_runs_parallel_tool_promises_and_returns_structured_values
    broker = Broker.new do |_name, arguments, id|
      sleep(0.03)
      Result.new(id:, value: {"echoed" => arguments.fetch("value")}, error: nil)
    end
    session = open_session(broker, limits: {max_concurrency: 4})
    result = execute(session, broker, <<~JAVASCRIPT)
      const values = await Promise.all([
        tools.echo_value({value: "one"}),
        tools.echo_value({value: "two"}),
        tools.echo_value({value: "three"})
      ]);
      text(values);
    JAVASCRIPT

    assert_equal :completed, result.status
    assert_equal [{"echoed" => "one"}, {"echoed" => "two"}, {"echoed" => "three"}], JSON.parse(result.output)
    assert_operator broker.maximum_concurrency, :>, 1
  end

  def test_bounds_parallel_tool_dispatch
    broker = Broker.new do |_name, arguments, id|
      sleep(0.02)
      Result.new(id:, value: arguments.fetch("value"), error: nil)
    end
    session = open_session(broker, limits: {max_concurrency: 2})
    result = execute(session, broker, <<~JAVASCRIPT)
      text(await Promise.all(Array.from({length: 6}, (_, index) => tools.echo_value({value: index}))));
    JAVASCRIPT

    assert_equal :completed, result.status
    assert_equal 2, broker.maximum_concurrency
  end

  def test_yields_and_resumes_incremental_output_from_the_same_cell
    broker = Broker.new
    session = open_session(broker)
    first = execute(
      session,
      broker,
      'text("before"); await yield_control(); text("middle"); await yield_control(); text("after");'
    )
    second = session.wait(yield_time_ms: 10_000, max_output_tokens: 1_000)
    third = session.wait(yield_time_ms: 10_000, max_output_tokens: 1_000)

    assert_equal [:yielded, :yielded, :completed], [first.status, second.status, third.status]
    assert_equal ["before", "middle", "after"], [first.output, second.output, third.output]
  end

  def test_terminates_a_yielded_cell
    broker = Broker.new
    session = open_session(broker)
    first = execute(session, broker, "await new Promise(() => {});", yield_time_ms: 5)
    client = session.instance_variable_get(:@client)
    captured = nil
    client.define_singleton_method(:terminate) do |**options|
      captured = options
      super(**options)
    end
    result = session.wait(terminate: true, max_output_tokens: 7)

    assert_equal :yielded, first.status
    assert_equal :terminated, result.status
    assert_equal 7, captured.fetch(:max_tokens)
  end

  def test_client_termination_honors_the_requested_output_budget
    owner = Object.new
    client = LittleGhost::CodeMode::Javascript::Client.new(session_factory: -> { flunk "unexpected host start" })
    cell = LittleGhost::CodeMode::Javascript::Client::Cell.new(
      id: "cell-1", owner:, dispatcher: Object.new
    )
    cell.output("abcdefghij")
    cell.complete(status: "completed")
    client.instance_variable_get(:@cells)[cell.id] = cell

    result = client.terminate(owner:, cell_id: cell.id, max_tokens: 1)

    assert_equal "ab…2 tokens truncated…ij", result.fetch(:output)
  ensure
    client&.close
  end

  def test_wait_context_cancellation_terminates_the_resumed_cell
    broker = Broker.new
    session = open_session(broker)
    first = execute(session, broker, "await new Promise(() => {});", yield_time_ms: 5)
    error = LittleGhost::CancelledError.new("cancelled while resuming")

    raised = assert_raises(LittleGhost::CancelledError) do
      session.wait(
        context: ContextError.new(error),
        yield_time_ms: 1_000,
        max_output_tokens: 1_000
      )
    end

    assert_equal :yielded, first.status
    assert_equal error.message, raised.message
    assert_raises(LittleGhost::ToolError) { session.wait }
  end

  def test_wait_requires_an_active_cell
    session = open_session(Broker.new)

    error = assert_raises(LittleGhost::ToolError) { session.wait }

    assert_includes error.message, "no active JavaScript cell"
  end

  def test_completion_drains_unawaited_tool_calls
    broker = Broker.new do |_name, arguments, id|
      sleep(0.03)
      Result.new(id:, value: arguments.fetch("value"), error: nil)
    end
    session = open_session(broker)
    result = execute(session, broker, 'tools.echo_value({value: "unawaited"}); text("done");')

    assert_equal :completed, result.status
    assert_equal "done", result.output
    assert_equal 1, broker.calls.length
  end

  def test_expected_tool_errors_remain_javascript_rejections
    broker = Broker.new do |_name, _arguments, id|
      Result.new(id:, value: nil, error: "expected failure")
    end
    session = open_session(broker)
    result = execute(session, broker, <<~JAVASCRIPT)
      try {
        await tools.echo_value({value: "test"});
      } catch (error) {
        text(error.message);
      }
    JAVASCRIPT

    assert_equal :completed, result.status
    assert_equal "expected failure", result.output
  end

  def test_unexpected_broker_failures_abort_the_session
    broker = Broker.new { raise "callback failed" }
    session = open_session(broker)

    error = assert_raises(LittleGhost::CleanupError) do
      execute(session, broker, 'await tools.echo_value({value: "test"});')
    end

    assert_includes error.message, "callback failed"
    assert_equal 1, broker.calls.length
  end

  def test_cancellation_and_deadline_errors_remain_routine_outcomes
    [
      LittleGhost::CancelledError.new("cancelled"),
      LittleGhost::DeadlineExceededError.new("expired")
    ].each do |routine_error|
      broker = Broker.new { raise routine_error }
      session = open_session(broker)

      raised = assert_raises(routine_error.class) do
        execute(session, broker, 'await tools.echo_value({value: "test"});')
      end
      assert_equal routine_error.message, raised.message
    end
  end

  def test_observation_context_cancellation_terminates_the_cell
    broker = Broker.new
    session = open_session(broker)
    error = LittleGhost::CancelledError.new("cancelled while waiting")

    raised = assert_raises(LittleGhost::CancelledError) do
      session.execute(
        source: "await new Promise(() => {});",
        catalog: broker.catalog,
        context: ContextError.new(error),
        yield_time_ms: 1_000,
        max_output_tokens: 1_000
      )
    end

    assert_equal error.message, raised.message
    assert_raises(LittleGhost::ToolError) { session.wait }
  end

  def test_script_failure_is_recoverable_in_a_fresh_v8_context
    broker = Broker.new
    session = open_session(broker)

    error = assert_raises(LittleGhost::ToolError) do
      execute(session, broker, 'throw new Error("model bug");')
    end
    recovered = execute(session, broker, 'text("recovered");')

    assert_includes error.message, "model bug"
    assert_equal :completed, recovered.status
    assert_equal "recovered", recovered.output
  end

  def test_uses_a_fresh_v8_context_for_each_completed_cell
    broker = Broker.new
    session = open_session(broker)
    first = execute(session, broker, 'globalThis.transient = "set"; text(transient);')
    second = execute(session, broker, "text(typeof transient);")

    assert_equal "set", first.output
    assert_equal "undefined", second.output
  end

  def test_host_loss_between_completed_cells_starts_a_fresh_process
    broker = Broker.new
    session = open_session(broker)
    assert_equal :completed, execute(session, broker, 'text("first");').status
    first_process = @sandboxes.last.processes.last

    _stdout, stderr = capture_io do
      Process.kill("KILL", -first_process.pid)
      Timeout.timeout(2) { sleep(0.005) until session.instance_variable_get(:@client).instance_variable_get(:@wait_thread).nil? }
      assert_equal :completed, execute(session, broker, 'text("second");').status
    end

    refute_equal first_process.pid, @sandboxes.last.processes.last.pid
    assert_includes stderr, "little_ghost_code_mode_host_exited"
    assert_includes stderr, "signal=SIGKILL"
  end

  def test_host_loss_after_accepted_work_is_fatal_and_does_not_repeat_the_tool
    entered = Queue.new
    release = Queue.new
    broker = Broker.new do |_name, arguments, id|
      entered << true
      release.pop
      Result.new(id:, value: arguments.fetch("value"), error: nil)
    end
    session = open_session(broker)
    execute(session, broker, 'await tools.echo_value({value: "test"});', yield_time_ms: 5)
    Timeout.timeout(1) { entered.pop }
    process = @sandboxes.last.processes.last
    Process.kill("KILL", -process.pid)
    release << true

    error = assert_raises(LittleGhost::CleanupError) do
      Timeout.timeout(2) { session.wait(yield_time_ms: 1_000) }
    end

    assert_includes error.message, "signal=SIGKILL"
    assert_equal 1, broker.calls.length
  ensure
    release << true if release
  end

  def test_host_failure_reports_status_and_redacted_stderr
    secret = "api_key=sk-super-secret"
    client = LittleGhost::CodeMode::Javascript::Client.new(session_factory: lambda {
      LittleGhost::Sandbox::ProcessSession.new(
        command: [RbConfig.ruby, "-e", "STDERR.write(#{secret.inspect}); exit 17"],
        output_bytes: 1_000_000
      )
    })
    broker = Broker.new
    session = LittleGhost::CodeMode::Javascript::Session.new(broker:, client:)
    @sessions << session

    error = assert_raises(LittleGhost::CleanupError) do
      execute(session, broker, 'text("unreachable");')
    end

    assert_includes error.message, "exit_status=17"
    assert_includes error.message, "stderr_bytes=#{secret.bytesize}"
    refute_includes error.message, secret
  end

  def test_fatal_client_termination_cannot_race_to_success
    cell = LittleGhost::CodeMode::Javascript::Client::Cell.new(
      id: "cell-1",
      owner: Object.new,
      dispatcher: Object.new
    )

    assert cell.request_client_termination("fatal host error")
    assert cell.claim_client_failure("host exited")
    cell.complete(status: "completed")
    result = cell.wait_until_terminal

    assert_equal "failed", result.fetch(:status)
    assert_equal "host exited", result.fetch(:error)
  end

  def test_cell_waits_without_a_timeout_until_the_full_terminal_result_arrives
    cell = LittleGhost::CodeMode::Javascript::Client::Cell.new(
      id: "cell-1",
      owner: Object.new,
      dispatcher: Object.new
    )
    completion = Thread.new do
      sleep 0.02
      cell.output("complete output")
      cell.complete(status: "completed")
    end

    result = cell.wait_until_terminal

    assert_equal "completed", result.fetch(:status)
    assert_equal "complete output", result.fetch(:output)
    completion.join
  end

  def test_cell_terminal_wait_has_an_explicit_cleanup_bound
    cell = LittleGhost::CodeMode::Javascript::Client::Cell.new(
      id: "cell-1",
      owner: Object.new,
      dispatcher: Object.new
    )

    error = assert_raises(LittleGhost::CleanupError) do
      cell.wait_until_terminal(timeout: 0.01)
    end

    assert_includes error.message, "cleanup timed out"
  end

  def test_output_limit_is_derived_from_the_protocol_buffer
    assert_equal 1_048_576, LittleGhost::CodeMode::Javascript::Session::MAX_OUTPUT_TOKENS
  end

  def test_protocol_round_trips_incremental_framed_json
    first = LittleGhost::CodeMode::Protocol.dump(type: "output", value: "one")
    second = LittleGhost::CodeMode::Protocol.dump(type: "complete")
    buffer = first.byteslice(0, 3)

    assert_nil LittleGhost::CodeMode::Protocol.extract!(buffer)
    buffer << first.byteslice(3..) << second
    assert_equal({"type" => "output", "value" => "one"}, LittleGhost::CodeMode::Protocol.extract!(buffer))
    assert_equal({"type" => "complete"}, LittleGhost::CodeMode::Protocol.extract!(buffer))
    assert_empty buffer
  end

  def test_rejects_javascript_identifier_collisions_and_reserved_names
    collision = [
      {name: "one-name", description: "one", input_schema: {}},
      {name: "one_name", description: "two", input_schema: {}}
    ]

    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::CodeMode::JavascriptEngine.new.instructions(catalog: collision)
    end
    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::CodeMode::JavascriptEngine.new.instructions(
        catalog: [{name: "exec", description: "reserved", input_schema: {}}]
      )
    end
  end

  def test_renders_supported_json_schema_as_typescript
    catalog = LittleGhost::CodeMode::Javascript::Catalog.new([{
      name: "search-tool",
      description: "Search safely.",
      input_schema: {
        type: "object",
        properties: {
          query: {type: "string", description: "Search query"},
          limit: {type: ["integer", "null"]},
          mode: {enum: %w[fast thorough]}
        },
        required: ["query"],
        additionalProperties: false
      }
    }])

    declarations = catalog.declarations
    assert_includes declarations, "search_tool(args: {"
    assert_includes declarations, "query: string;"
    assert_includes declarations, "limit?: number | null;"
    assert_includes declarations, 'mode?: "fast" | "thorough";'
  end

  def test_preserves_nested_parameter_instructions_for_host_and_typescript_callers
    description = "For Shared Drive operations, explicitly include supportsAllDrives: 'true'."
    catalog = LittleGhost::CodeMode::Javascript::Catalog.new([{
      name: "google_api_request",
      description: "Call Google APIs.",
      input_schema: {
        type: "object",
        properties: {
          params: {type: "object", description:, additionalProperties: true}
        }
      }
    }])

    assert_equal description,
      catalog.host_definitions.first.dig("input_schema", :properties, :params, :description)
    assert_includes catalog.declarations, description
    assert_includes catalog.declarations, "params?: {"
  end

  def test_session_owns_and_closes_the_sandbox_workspace_and_process
    broker = Broker.new
    session = open_session(broker)
    workspace = session.instance_variable_get(:@workspace)
    root = workspace.root
    execute(session, broker, 'text("done");')

    session.close

    assert @sandboxes.last.closed?
    refute File.exist?(root)
    assert_raises(LittleGhost::ToolError) { execute(session, broker, 'text("closed");') }
  end

  def test_runtime_paths_follow_the_loaded_optional_gems
    specification = Struct.new(:full_gem_path, :extension_dir, :full_require_paths)
    specifications = {
      "mini_racer" => specification.new(
        "/bundle/mini_racer", "/missing/extension", ["/bundle/mini_racer/lib", "/bundle/mini_racer/ext"]
      ),
      "libv8-node" => specification.new(
        "/bundle/libv8-node", "/missing/extension", ["/bundle/libv8-node/lib"]
      )
    }

    paths = LittleGhost::CodeMode::JavascriptEngine.new.send(
      :javascript_runtime_paths,
      specifications:
    )

    assert_equal "/bundle/mini_racer", paths.fetch(:mini_racer_gem)
    assert_equal "/bundle/libv8-node", paths.fetch(:libv8_node_gem)

    command = LittleGhost::CodeMode::JavascriptEngine.new.send(:host_command, specifications:)
    assert_includes command.each_cons(2).to_a, ["-I", "/bundle/mini_racer/lib"]
    assert_includes command.each_cons(2).to_a, ["-I", "/bundle/mini_racer/ext"]
    assert_includes command.each_cons(2).to_a, ["-I", "/bundle/libv8-node/lib"]
  end

  private

  def execute(session, broker, source, yield_time_ms: 10_000)
    session.execute(
      source:,
      catalog: broker.catalog,
      yield_time_ms:,
      max_output_tokens: 1_000
    )
  end

  def open_session(broker, limits: {})
    engine = LittleGhost::CodeMode::JavascriptEngine.new
    sandbox_factory = lambda do |workspace:, required_runtime_paths:|
      assert_equal workspace.paths.keys.to_h { |name| [name, :read_only] }, required_runtime_paths
      assert_equal Gem.loaded_specs.fetch("mini_racer").full_gem_path, workspace.path(:mini_racer_gem)
      assert_equal Gem.loaded_specs.fetch("libv8-node").full_gem_path, workspace.path(:libv8_node_gem)
      Sandbox.new(workspace).tap { |sandbox| @sandboxes << sandbox }
    end
    engine.open_session(broker:, sandbox_factory:, limits: {cpu_seconds: nil}.merge(limits)).tap do |session|
      @sessions << session
    end
  end
end
