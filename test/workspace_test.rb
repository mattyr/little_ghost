# frozen_string_literal: true

require "test_helper"
require "async"

class WorkspaceTest < Minitest::Test
  Run = Data.define(:id)

  def test_exposes_absolute_named_paths
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(
        root:,
        paths: {attachments: "attachments", cache: File.join(root, "shared-cache")}
      )

      assert_equal File.join(root, "attachments"), workspace.path(:attachments)
      assert_equal File.join(root, "shared-cache"), workspace.path("cache")
      assert_predicate workspace.paths, :frozen?
      assert_predicate workspace.path(:cache), :frozen?
      assert_raises(KeyError) { workspace.path(:missing) }
    end
  end

  def test_resolves_relative_paths_from_the_filesystem_root
    workspace = LittleGhost::Workspace.new(root: File::SEPARATOR, paths: {tmp: "tmp"})

    assert_equal File.join(File::SEPARATOR, "tmp"), workspace.path(:tmp)
  end

  def test_runs_configured_lifecycle_once
    events = []
    run = Run.new("run-1")
    workspace = LittleGhost::Workspace.new(
      root: Dir.pwd,
      setup: ->(workspace:, run:) { events << [:setup, workspace, run] },
      teardown: ->(workspace:, run:) { events << [:teardown, workspace, run] }
    )

    assert_same workspace, workspace.open(run:)
    assert_same workspace, workspace.open(run:)
    assert_nil workspace.close
    assert_nil workspace.close
    assert_equal [[:setup, workspace, run], [:teardown, workspace, run]], events
  end

  def test_resolves_and_formats_logical_paths_without_exposing_absolute_paths
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {skills: "skills"}).open

      assert_equal File.join(root, "guide.md"), workspace.resolve("guide.md")
      assert_equal File.join(root, "skills", "guide.md"), workspace.resolve("workspace://skills/guide.md")
      assert_equal "workspace://skills/guide.md", workspace.reference(File.join(root, "skills", "guide.md"))
      assert_raises(ArgumentError) { workspace.resolve(File.join(root, "guide.md")) }
      assert_raises(ArgumentError) { workspace.resolve("../secret") }
    ensure
      workspace&.close
    end
  end

  def test_open_materializes_paths_and_rejects_physical_aliases
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {cache: "cache"}).open

      assert File.directory?(workspace.path(:cache))
      assert_equal root, workspace.environment.fetch("LITTLE_GHOST_WORKSPACE_ROOT")
      assert_equal workspace.path(:cache), workspace.environment.fetch("LITTLE_GHOST_WORKSPACE_CACHE")
    ensure
      workspace&.close
    end

    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "shared"))
      aliased = LittleGhost::Workspace.new(root:, paths: {one: "shared", two: "shared"})

      assert_raises(ArgumentError) { aliased.open }
    end
  end

  def test_open_keeps_setup_and_filesystem_work_on_the_scheduler_thread
    Dir.mktmpdir do |root|
      started = Queue.new
      release = Queue.new
      setup_thread = nil
      filesystem_thread = nil
      scheduler_thread = nil
      original_mkdir_p = FileUtils.method(:mkdir_p)
      workspace = LittleGhost::Workspace.new(
        root:,
        setup: ->(**) { setup_thread = Thread.current }
      )

      Async do |task|
        scheduler_thread = Thread.current
        opening = task.async do
          FileUtils.stub(:mkdir_p, lambda { |*args, **options|
            filesystem_thread = Thread.current
            started << true
            release.pop
            original_mkdir_p.call(*args, **options)
          }) { workspace.open }
        end
        started.pop
        release << true
        opening.wait
      end.wait

      assert_same scheduler_thread, setup_thread
      assert_same scheduler_thread, filesystem_thread
      assert_same workspace, workspace.validate!
    ensure
      release&.push(true)
      workspace&.close
    end
  end

  def test_open_requires_absolute_named_paths_to_exist_without_creating_them
    Dir.mktmpdir do |root|
      external = File.join(root, "missing-external")
      workspace = LittleGhost::Workspace.new(root: File.join(root, "workspace"), paths: {runtime: external})

      error = assert_raises(ArgumentError) { workspace.open }

      assert_includes error.message, "must already exist"
      refute File.exist?(external)
    end
  end

  def test_tears_down_partially_opened_workspace
    events = []
    workspace = LittleGhost::Workspace.new(
      root: Dir.pwd,
      setup: ->(**) { raise "setup failed" },
      teardown: ->(**) { events << :teardown }
    )

    error = assert_raises(RuntimeError) { workspace.open }

    assert_equal "setup failed", error.message
    assert_equal [:teardown], events
    assert_nil workspace.close
  end

  def test_rejects_invalid_configuration
    assert_raises(ArgumentError) { LittleGhost::Workspace.new(root: Dir.pwd, paths: []) }
    assert_raises(ArgumentError) do
      LittleGhost::Workspace.new(root: Dir.pwd, paths: {cache: "../cache"})
    end
    assert_raises(ArgumentError) { LittleGhost::Workspace.new(root: Dir.pwd, setup: Object.new) }
    assert_raises(ArgumentError) { LittleGhost::Workspace.new(root: Dir.pwd, teardown: Object.new) }
  end
end
