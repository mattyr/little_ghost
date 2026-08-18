# frozen_string_literal: true

require "test_helper"

class SandboxPolicyTest < Minitest::Test
  def test_policy_uses_named_files_and_process_only_runtime_paths
    policy = LittleGhost::Sandbox::Policy.new(
      files: {root: :read_write, source: :read_only},
      runtime_paths: {home: :read_write},
      environment: {"MODE" => "test"},
      network: :none
    )

    assert_equal({root: :read_write, source: :read_only}, policy.files)
    assert_equal({home: :read_write}, policy.runtime_paths)
    assert_equal :isolated, policy.root_filesystem
    assert_equal({"MODE" => "test"}, policy.environment.to_h)
    assert_predicate policy.network, :none?
    refute_respond_to policy, :mounts
    refute_respond_to policy, :workspace_path
  end

  def test_policy_rejects_unknown_and_invalid_path_access
    assert_raises(ArgumentError) do
      LittleGhost::Sandbox::Policy.new(mounts: [])
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::Policy.new(files: {root: :execute})
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::Policy.new(root_filesystem: :host)
    end
  end

  def test_scopes_narrow_named_paths_without_promoting_runtime_paths
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(
        root:,
        paths: {source: "source", home: "home"}
      ).open
      File.write(File.join(workspace.path(:source), "guide.md"), "guide")
      File.write(File.join(workspace.path(:home), "secret.txt"), "secret")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {root: :read_write, source: :read_only},
          runtime_paths: {home: :read_write},
          network: :inherit
        }
      )
      scope = sandbox.scope(files: [:source], runtime_paths: [])

      assert_equal "guide", scope.read("workspace://source/guide.md")
      assert_raises(LittleGhost::ToolError) { scope.read("workspace://home/secret.txt") }
      assert_raises(LittleGhost::ToolError) { scope.write("workspace://source/new.md", "no") }
    ensure
      workspace&.close
    end
  end

  def test_nested_scopes_inherit_the_parent_current_file_and_runtime_grants
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(
        root:,
        paths: {source: "source", home: "home"}
      ).open
      File.write(File.join(root, "root.txt"), "root")
      File.write(File.join(workspace.path(:source), "guide.md"), "guide")
      File.write(File.join(workspace.path(:home), "secret.txt"), "secret")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {root: :read_write, source: :read_only},
          runtime_paths: {home: :read_write},
          network: :inherit
        }
      )
      parent = sandbox.scope(files: [:source], runtime_paths: [:home])

      without_runtime = parent.scope(runtime_paths: [])
      without_files = parent.scope(files: [])

      assert_equal "guide", without_runtime.read("workspace://source/guide.md")
      assert_raises(LittleGhost::ToolError) { without_runtime.read("root.txt") }
      assert_empty without_runtime.process_grants.reject(&:tool_visible?)
      assert_raises(LittleGhost::ToolError) { without_files.read("workspace://home/secret.txt") }
      assert_empty without_files.process_grants.select(&:tool_visible?)
      assert_equal [File.realpath(workspace.path(:home))], without_files.process_grants.map(&:source)
    ensure
      workspace&.close
    end
  end

  def test_nested_file_shorthand_uses_the_matching_parent_access
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {source: "source"}).open
      File.write(File.join(workspace.path(:source), "guide.md"), "guide")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {root: :read_write, source: :read_write}, network: :inherit}
      )
      parent = sandbox.scope(files: {source: :read_only}, runtime_paths: [])

      nested = parent.scope(files: [:source])

      assert_equal "guide", nested.read("workspace://source/guide.md")
      assert_raises(LittleGhost::ToolError) { nested.write("workspace://source/new.md", "no") }
      assert_equal [:read_only], nested.process_grants.map(&:access)
      assert nested.process_grants.all?(&:tool_visible?)
    ensure
      workspace&.close
    end
  end

  def test_nested_runtime_shorthand_uses_the_matching_parent_access_and_visibility
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {home: "home"}).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {root: :read_write},
          runtime_paths: {home: :read_write},
          network: :inherit
        }
      )
      parent = sandbox.scope(files: [], runtime_paths: {home: :read_only})

      nested = parent.scope(runtime_paths: [:home])

      assert_equal [:read_only], nested.process_grants.map(&:access)
      refute nested.process_grants.any?(&:tool_visible?)
      assert_raises(LittleGhost::ToolError) { nested.read("workspace://home/secret.txt") }
    ensure
      workspace&.close
    end
  end

  def test_nested_explicit_files_cannot_promote_a_runtime_only_parent_grant
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {home: "home"}).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {root: :read_write},
          runtime_paths: {home: :read_write},
          network: :inherit
        }
      )
      parent = sandbox.scope(files: [:root], runtime_paths: [:home])

      error = assert_raises(LittleGhost::CapabilityError) do
        parent.scope(files: {home: :read_only})
      end

      assert_includes error.message, "outside its parent"
    ensure
      workspace&.close
    end
  end

  def test_nested_explicit_runtime_paths_cannot_hide_a_tool_visible_parent_grant
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {source: "source"}).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {root: :read_write, source: :read_only}, network: :inherit}
      )
      parent = sandbox.scope(files: [:source], runtime_paths: [])

      error = assert_raises(LittleGhost::CapabilityError) do
        parent.scope(runtime_paths: {source: :read_only})
      end

      assert_includes error.message, "outside its parent"
    ensure
      workspace&.close
    end
  end

  def test_nested_scope_preserves_runtime_visibility_for_same_name_dual_category_grants
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {shared: "shared"}).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {shared: :read_write},
          runtime_paths: {shared: :read_only},
          network: :inherit
        }
      )
      parent = sandbox.scope(files: [:shared], runtime_paths: [:shared])

      shorthand = parent.scope(files: [], runtime_paths: [:shared])
      explicit = parent.scope(files: [], runtime_paths: {shared: :read_only})

      [shorthand, explicit].each do |nested|
        assert_equal [:read_only], nested.process_grants.map(&:access)
        refute nested.process_grants.any?(&:tool_visible?)
        assert_raises(LittleGhost::ToolError) { nested.read("workspace://shared/secret.txt") }
      end
    ensure
      workspace&.close
    end
  end

  def test_process_environment_includes_workspace_identity_paths
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {cache: "cache"}).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)

      result = sandbox.execute_program(
        [RbConfig.ruby, "-e", "print ENV.fetch('LITTLE_GHOST_WORKSPACE_CACHE')"],
        timeout: 1
      )

      assert_equal workspace.path(:cache), result.stdout
    ensure
      workspace&.close
    end
  end
end
