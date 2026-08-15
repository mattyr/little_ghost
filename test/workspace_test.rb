# frozen_string_literal: true

require "test_helper"

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
