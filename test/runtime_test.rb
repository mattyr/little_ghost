# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "test_helper"

class RuntimeTest < Minitest::Test
  class RecordingInstrumentation < TestTelemetryRecorder
    attr_reader :events, :flush_count

    def initialize
      super
      @flush_count = 0
    end

    def flush(timeout: nil)
      @flush_count += 1
    end
  end

  class RecordingEvents
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event)
      @events << event
    end
  end

  def test_runtime_emits_a_ready_startup_lifecycle
    Dir.mktmpdir do |root|
      instrumentation = RecordingInstrumentation.new
      LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(subscribers: [instrumentation])
      events = RecordingEvents.new
      LittleGhost::Events.subscribe(events)
      configuration = LittleGhost::Configuration.new(
        root:,
        service_name: "runtime-test"
      )

      runtime = LittleGhost::Runtime.new(configuration:)

      assert_equal File.realpath(root), runtime.root.to_s
      assert_equal [:runtime_start, :runtime_stop], instrumentation.events.map(&:first)
      assert_equal "ready", instrumentation.events.last.last.fetch(:outcome)
      assert_equal 0, instrumentation.flush_count
      startup = events.events.last
      assert_equal "little_ghost.runtime.startup", startup.fetch(:name)
      assert_equal :info, startup.fetch(:level)
      assert_equal "ready", startup.dig(:payload, :status)
      assert_equal "runtime-test", startup.dig(:payload, :service_name)
    end
  end

  def test_runtime_uses_the_default_models_when_files_are_not_configured
    Dir.mktmpdir do |root|
      runtime = LittleGhost::Runtime.new(configuration: LittleGhost::Configuration.new(root:))

      assert_instance_of LittleGhost::ModelResolver, runtime.model_resolver
    end
  end

  def test_runtime_forwards_agent_model_selections_without_coercion
    resolver = Object.new
    selections = []
    resolver.define_singleton_method(:resolve) do |selection, **|
      selections << selection
      Object.new
    end
    runtime = LittleGhost::Runtime.allocate
    runtime.instance_variable_set(:@model_resolver, resolver)
    runtime.instance_variable_set(:@default_model, "default")
    invocation = LittleGhost::Invocation.new(message: "hello")
    run = Data.define(:invocation).new(invocation)
    role_agent = Class.new(LittleGhost::Agent) { model :customer_support }
    target_agent = Class.new(LittleGhost::Agent) { model "openai:gpt-5.6-luna" }
    inline_agent = Class.new(LittleGhost::Agent) { model(provider: "openai", model: "gpt-5.6-luna") }

    runtime.model_for(role_agent, run)
    runtime.model_for(target_agent, run)
    runtime.model_for(inline_agent, run)

    assert_equal [
      :customer_support,
      "openai:gpt-5.6-luna",
      {provider: "openai", model: "gpt-5.6-luna"}
    ], selections
  end

  def test_runtime_reports_failed_startup_and_flushes_telemetry
    Dir.mktmpdir do |root|
      write(root, "app/agents/conflict_agent.rb", "class ConflictAgent; end")
      write(root, "app/tools/conflict_agent.rb", "class ConflictAgent; end")
      instrumentation = RecordingInstrumentation.new
      LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(subscribers: [instrumentation])
      events = RecordingEvents.new
      LittleGhost::Events.subscribe(events)
      configuration = LittleGhost::Configuration.new(
        root:,
        service_name: "runtime-test"
      )
      error = assert_raises(LittleGhost::Support::Loader::ConflictError) do
        LittleGhost::Runtime.new(configuration:)
      end

      assert_equal [:runtime_start, :runtime_stop], instrumentation.events.map(&:first)
      failure = instrumentation.events.last.last
      assert_equal "failed", failure.fetch(:outcome)
      assert_equal error.class.name, failure.fetch(:error_type)
      assert_equal error.class.name, JSON.parse(failure.fetch(:diagnostic_exception)).fetch("type")
      assert_equal 1, instrumentation.flush_count
      startup = events.events.last
      assert_equal :error, startup.fetch(:level)
      assert_equal "loader", startup.dig(:payload, :phase)
      assert_equal "failed", startup.dig(:payload, :status)
      assert_equal error.class.name, startup.dig(:payload, :error_type)
    end
  end

  def test_runtime_builds_workspace_and_sandbox_from_explicit_class_providers
    Dir.mktmpdir do |root|
      workspace_class = Class.new(LittleGhost::Workspace) do
        class << self
          attr_accessor :root
        end

        def initialize
          super(root: self.class.root)
        end
      end
      workspace_class.root = root
      sandbox_class = Class.new(LittleGhost::Sandboxes::Unrestricted)
      configuration = LittleGhost::Configuration.new(root:)
      configuration.workspace = {provider: workspace_class}
      configuration.sandbox = {provider: sandbox_class}
      runtime = LittleGhost::Runtime.new(configuration:)

      built_workspace = runtime.build_workspace
      built_sandbox = runtime.build_sandbox(workspace: built_workspace)

      assert_instance_of workspace_class, built_workspace
      assert_instance_of sandbox_class, built_sandbox
      assert_same built_workspace, built_sandbox.workspace
    end
  end

  def test_resource_configuration_rejects_bare_classes
    configuration = LittleGhost::Configuration.new

    assert_raises(ArgumentError) { configuration.workspace = Object }
    assert_raises(ArgumentError) { configuration.sandbox = Object }
    assert_raises(ArgumentError) { configuration.workspace = LittleGhost::Workspace }
    assert_raises(ArgumentError) { configuration.sandbox = LittleGhost::Sandboxes::Unrestricted }
    assert_raises(ArgumentError) { configuration[:workspace] = LittleGhost::Workspace }
    assert_raises(ArgumentError) { configuration[:sandbox] = LittleGhost::Sandboxes::Unrestricted }
    assert_raises(ArgumentError) do
      LittleGhost::Configuration.new(workspace: LittleGhost::Workspace)
    end
    assert_raises(ArgumentError) do
      LittleGhost::Configuration.new(sandbox: LittleGhost::Sandboxes::Unrestricted)
    end
  end

  def test_runtime_builds_resources_from_provider_declarations
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "work"))
      configuration = LittleGhost::Configuration.new(root:)
      configuration.workspace = {provider: :directory, root: "work"}
      configuration.sandbox = {
        provider: :unrestricted,
        workspace_access: :read_write,
        network: :inherit
      }
      runtime = LittleGhost::Runtime.new(configuration:)

      workspace = runtime.build_workspace
      sandbox = runtime.build_sandbox(workspace:)

      assert_equal File.join(runtime.root, "work"), workspace.root
      assert_instance_of LittleGhost::Sandboxes::Unrestricted, sandbox
      assert sandbox.writable?
      assert_equal :inherit, sandbox.policy.network.mode
      assert_equal :read_write, sandbox.effective_policy.root_filesystem
    end
  end

  def test_runtime_passes_context_to_callable_resource_providers
    Dir.mktmpdir do |root|
      received = []
      workspace_provider = lambda do |runtime:, invocation:, root:|
        received << [runtime, invocation]
        LittleGhost::Workspace.new(root:)
      end
      sandbox_provider = lambda do |runtime:, invocation:, workspace:, policy:|
        received << [runtime, invocation, workspace]
        LittleGhost::Sandboxes::Unrestricted.new(workspace:, policy:)
      end
      configuration = LittleGhost::Configuration.new(root:)
      configuration.workspace = {provider: workspace_provider, root:}
      configuration.sandbox = {provider: sandbox_provider, network: :inherit}
      runtime = LittleGhost::Runtime.new(configuration:)

      run = runtime.build_run({message: "hello"}, agent_class: LittleGhost::Agent)

      assert_same runtime, received.fetch(0).fetch(0)
      assert_same run.invocation, received.fetch(0).fetch(1)
      assert_same run.invocation, received.fetch(1).fetch(1)
      assert_same run.workspace, received.fetch(1).fetch(2)
    ensure
      run&.close
    end
  end

  def test_runtime_does_not_fall_back_for_an_unknown_sandbox_provider
    configuration = LittleGhost::Configuration.new
    configuration.sandbox = :missing
    runtime = LittleGhost::Runtime.new(configuration:)
    workspace = runtime.build_workspace

    error = assert_raises(LittleGhost::DependencyError) do
      runtime.build_sandbox(workspace:)
    end

    assert_match(/provider :missing is not available/, error.message)
  end

  def test_runtime_gives_each_run_its_own_default_workspace_and_sandbox
    Dir.mktmpdir do |root|
      workspace_class = tracked_workspace_class(root)
      sandbox_class = tracked_sandbox_class
      configuration = LittleGhost::Configuration.new(
        root:,
        workspace: {provider: workspace_class},
        sandbox: {provider: sandbox_class}
      )
      runtime = LittleGhost::Runtime.new(configuration:)

      first = runtime.build_run({message: "first"}, agent_class: LittleGhost::Agent)
      second = runtime.build_run({message: "second"}, agent_class: LittleGhost::Agent)

      refute_same first.workspace, second.workspace
      refute_same first.sandbox, second.sandbox
      assert_same first.workspace, first.sandbox.workspace
      assert_same second.workspace, second.sandbox.workspace

      first.close

      assert first.workspace.closed
      assert first.sandbox.closed
      refute second.workspace.closed
      refute second.sandbox.closed
    end
  end

  def test_runtime_closes_a_workspace_when_sandbox_creation_fails
    Dir.mktmpdir do |root|
      workspace_class = tracked_workspace_class(root)
      sandbox_class = Class.new(LittleGhost::Sandbox) do
        def initialize(workspace:)
          raise "sandbox failed"
        end
      end
      configuration = LittleGhost::Configuration.new(
        root:,
        workspace: {provider: workspace_class},
        sandbox: {provider: sandbox_class}
      )
      runtime = LittleGhost::Runtime.new(configuration:)

      error = assert_raises(RuntimeError) do
        runtime.build_run({message: "hello"}, agent_class: LittleGhost::Agent)
      end

      assert_equal "sandbox failed", error.message
      assert workspace_class.instances.first.closed
    end
  end

  def test_runtime_builds_a_composite_assembly_directly
    runtime = LittleGhost::Runtime.allocate
    assembly_class = Class.new(LittleGhost::Assembly)
    run = Struct.new(:runtime, :workspace, :sandbox).new(runtime, nil, nil)

    assembly = runtime.build_assembly(assembly_class, run:)

    assert_kind_of LittleGhost::Assembly, assembly
    assert_equal assembly_class.assembly_id, assembly.class.assembly_id
    assert_same run, assembly.run
    assert_same runtime, assembly.runtime
  end

  private

  def write(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def tracked_workspace_class(root)
    Class.new(LittleGhost::Workspace) do
      class << self
        attr_accessor :root, :instances
      end

      def initialize
        super(root: self.class.root)
        self.class.instances << self
      end

      attr_reader :closed

      def close = @closed = true
    end.tap do |klass|
      klass.root = root
      klass.instances = []
    end
  end

  def tracked_sandbox_class
    Class.new(LittleGhost::Sandbox) do
      class << self
        attr_accessor :instances
      end

      def initialize(workspace:)
        super
        self.class.instances << self
      end

      attr_reader :closed

      def close = @closed = true
    end.tap { |klass| klass.instances = [] }
  end
end
