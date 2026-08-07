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

  def test_runtime_builds_workspace_and_sandbox_from_configured_builders
    Dir.mktmpdir do |root|
      calls = []
      workspace = LittleGhost::Workspace.new(root:)
      sandbox = LittleGhost::UnrestrictedSandbox.new(workspace:)
      configuration = LittleGhost::Configuration.new(root:)
      configuration.workspace do |runtime:|
        calls << [:workspace, runtime]
        workspace
      end
      configuration.sandbox do |workspace:, runtime:|
        calls << [:sandbox, workspace, runtime]
        sandbox
      end
      runtime = LittleGhost::Runtime.new(configuration:)

      built_workspace = runtime.build_workspace
      built_sandbox = runtime.build_sandbox(workspace: built_workspace)

      assert_same workspace, built_workspace
      assert_same sandbox, built_sandbox
      assert_equal [[:workspace, runtime], [:sandbox, workspace, runtime]], calls
    end
  end

  def test_resource_configuration_requires_callable_builders
    configuration = LittleGhost::Configuration.new

    assert_raises(ArgumentError) { configuration.workspace LittleGhost::Workspace }
    assert_raises(ArgumentError) { configuration.sandbox LittleGhost::Sandbox }
  end

  private

  def write(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
