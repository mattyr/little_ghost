# frozen_string_literal: true

require "test_helper"

class SandboxFilesystemTest < Minitest::Test
  def test_rejects_symbolic_links_in_intermediate_path_components
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "documents"))
      File.write(File.join(root, "documents", "report.txt"), "report")
      File.symlink("documents", File.join(root, "alias"))
      scope = writable_scope(root)

      assert_raises(LittleGhost::ToolError) { scope.read("alias/report.txt") }
      assert_raises(LittleGhost::ToolError) { scope.list("alias") }
      assert_raises(LittleGhost::ToolError) { scope.write("alias/new.txt", "changed") }
      refute_path_exists File.join(root, "documents", "new.txt")
    end
  end

  def test_nested_read_only_mount_is_not_widened_by_the_writable_workspace
    Dir.mktmpdir do |root|
      attachments = File.join(root, "attachments")
      FileUtils.mkdir_p(attachments)
      policy = {
        workspace_access: :read_write,
        network: :inherit,
        mounts: [{source: attachments, target: "/workspace/attachments", access: :read_only}]
      }
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace: LittleGhost::Workspace.new(root:), policy:)
      scope = sandbox.scope

      refute scope.allows?(:filesystem_write, "/workspace/attachments/new.txt")
      assert_raises(LittleGhost::ToolError) do
        scope.write("/workspace/attachments/new.txt", "changed")
      end
      refute_path_exists File.join(attachments, "new.txt")
    end
  end

  def test_read_cannot_escape_when_an_ancestor_is_replaced_after_the_mount_is_opened
    with_ancestor_swap do |scope, root, target, swap|
      original_open = File.method(:open)
      replacement = raced_open(original_open, root:, target:, swap:)

      assert_raises(LittleGhost::ToolError) do
        File.stub(:open, replacement) { scope.read("allowed/report.txt") }
      end
    end
  end

  def test_write_cannot_escape_when_an_ancestor_is_replaced_after_the_mount_is_opened
    with_ancestor_swap do |scope, root, target, swap, outside|
      original_open = File.method(:open)
      replacement = raced_open(original_open, root:, target:, swap:)

      assert_raises(LittleGhost::ToolError) do
        File.stub(:open, replacement) { scope.write("allowed/report.txt", "changed") }
      end
      assert_equal "outside", File.read(File.join(outside, "report.txt"))
    end
  end

  private

  def writable_scope(root)
    sandbox = LittleGhost::Sandboxes::Unrestricted.new(
      workspace: LittleGhost::Workspace.new(root:),
      policy: {workspace_access: :read_write, network: :inherit}
    )
    sandbox.scope
  end

  def with_ancestor_swap
    Dir.mktmpdir do |container|
      root = File.join(container, "workspace")
      outside = File.join(container, "outside")
      allowed = File.join(root, "allowed")
      displaced = File.join(root, "displaced")
      FileUtils.mkdir_p(allowed)
      FileUtils.mkdir_p(outside)
      File.write(File.join(allowed, "report.txt"), "inside")
      File.write(File.join(outside, "report.txt"), "outside")
      scope = writable_scope(root)
      root = File.realpath(root)
      target = File.realpath(File.join(allowed, "report.txt"))
      swapped = false
      swap = lambda do
        next if swapped

        File.rename(allowed, displaced)
        File.symlink(outside, allowed)
        swapped = true
      end

      yield scope, root, target, swap, outside
    end
  end

  def raced_open(original, root:, target:, swap:)
    lambda do |path, *arguments, **options, &block|
      path = String(path)
      if path == root
        opened = original.call(path, *arguments, **options, &block)
        swap.call
        opened
      else
        swap.call if path == target
        original.call(path, *arguments, **options, &block)
      end
    end
  end
end
