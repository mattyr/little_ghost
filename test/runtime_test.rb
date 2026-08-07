# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "test_helper"

class RuntimeTest < Minitest::Test
  class RecordingInstrumentation
    attr_reader :events, :flush_count

    def initialize
      @events = []
      @flush_count = 0
    end

    def emit(name, **attributes)
      @events << [name, attributes]
    end

    def flush
      @flush_count += 1
    end
  end

  def test_runtime_emits_a_ready_startup_lifecycle
    Dir.mktmpdir do |root|
      instrumentation = RecordingInstrumentation.new
      log = StringIO.new
      configuration = LittleGhost::Configuration.new(
        root:,
        service_name: "runtime-test",
        instrumentation:
      )

      runtime = LittleGhost::Runtime.new(configuration:, logger: Logger.new(log))

      assert_equal File.realpath(root), runtime.root.to_s
      assert_equal [:runtime_start, :runtime_stop], instrumentation.events.map(&:first)
      assert_equal "ready", instrumentation.events.last.last.fetch(:outcome)
      assert_equal 0, instrumentation.flush_count
      assert_includes log.string, "little_ghost_runtime_boot status=ready"
    end
  end

  def test_runtime_reports_failed_startup_and_flushes_telemetry
    Dir.mktmpdir do |root|
      write(root, "app/agents/conflict_agent.rb", "class ConflictAgent; end")
      write(root, "app/tools/conflict_agent.rb", "class ConflictAgent; end")
      instrumentation = RecordingInstrumentation.new
      log = StringIO.new
      configuration = LittleGhost::Configuration.new(
        root:,
        service_name: "runtime-test",
        instrumentation:
      )
      error = assert_raises(LittleGhost::Support::Loader::ConflictError) do
        LittleGhost::Runtime.new(configuration:, logger: Logger.new(log))
      end

      assert_equal [:runtime_start, :runtime_stop], instrumentation.events.map(&:first)
      failure = instrumentation.events.last.last
      assert_equal "failed", failure.fetch(:outcome)
      assert_equal error.class.name, failure.fetch(:error_type)
      assert_equal error.class.name, JSON.parse(failure.fetch(:diagnostic_exception)).fetch("type")
      assert_equal 1, instrumentation.flush_count
      assert_includes log.string, "phase=loader"
      assert_includes log.string, "status=failed"
    end
  end

  def test_runtime_builds_workspace_and_sandbox_from_configured_classes
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
      sandbox_class = Class.new(LittleGhost::UnrestrictedSandbox)
      configuration = LittleGhost::Configuration.new(root:)
      configuration.workspace = workspace_class
      configuration.sandbox = sandbox_class
      runtime = LittleGhost::Runtime.new(configuration:)

      built_workspace = runtime.build_workspace
      built_sandbox = runtime.build_sandbox(workspace: built_workspace)

      assert_instance_of workspace_class, built_workspace
      assert_instance_of sandbox_class, built_sandbox
      assert_same built_workspace, built_sandbox.workspace
    end
  end

  def test_resource_configuration_requires_component_classes
    configuration = LittleGhost::Configuration.new

    assert_raises(ArgumentError) { configuration.workspace = Object }
    assert_raises(ArgumentError) { configuration.sandbox = Object }
  end

  def test_runtime_gives_each_run_its_own_default_workspace_and_sandbox
    Dir.mktmpdir do |root|
      workspace_class = tracked_workspace_class(root)
      sandbox_class = tracked_sandbox_class
      configuration = LittleGhost::Configuration.new(root:, workspace: workspace_class, sandbox: sandbox_class)
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
      configuration = LittleGhost::Configuration.new(root:, workspace: workspace_class, sandbox: sandbox_class)
      runtime = LittleGhost::Runtime.new(configuration:)

      error = assert_raises(RuntimeError) do
        runtime.build_run({message: "hello"}, agent_class: LittleGhost::Agent)
      end

      assert_equal "sandbox failed", error.message
      assert workspace_class.instances.first.closed
    end
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
