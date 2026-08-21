# frozen_string_literal: true

require "test_helper"
require "async"

class SandboxFilesystemTest < Minitest::Test
  def test_filesystem_operations_use_scheduler_native_io
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)
      filesystem = sandbox.scope.instance_variable_get(:@filesystem)
      operation_thread = nil
      original = filesystem.method(:read_path)
      filesystem.define_singleton_method(:read_path) do |path, context: nil|
        operation_thread = Thread.current
        original.call(path, context:)
      end
      File.write(File.join(root, "note.txt"), "hello")

      Async do
        scheduler_thread = Thread.current
        assert_equal "hello", filesystem.read("note.txt")
        assert_same scheduler_thread, operation_thread
      end
    ensure
      workspace&.close
    end
  end

  def test_filesystem_tools_use_logical_paths_and_reject_physical_paths
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:, paths: {source: "source"}).open
      File.write(File.join(workspace.path(:source), "readme.md"), "hello")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {root: :read_write, source: :read_only}, network: :inherit}
      )

      assert_equal "hello", sandbox.read("workspace://source/readme.md")
      assert_raises(LittleGhost::ToolError) { sandbox.read(File.join(workspace.path(:source), "readme.md")) }
      assert_raises(LittleGhost::ToolError) { sandbox.write("workspace://source/new.md", "no") }
      assert_equal "Wrote 3 bytes to #{File.join(root, "new.md")}", sandbox.write("new.md", "yes")
    ensure
      workspace&.close
    end
  end

  def test_symlink_traversal_is_rejected
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret"), "secret")
        File.symlink(outside, File.join(root, "escape"))
        workspace = LittleGhost::Workspace.new(root:).open
        sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)

        assert_raises(LittleGhost::ToolError) { sandbox.read("escape/secret") }
      ensure
        workspace&.close
      end
    end
  end

  def test_hardlinks_cannot_alias_read_only_or_runtime_only_files
    Dir.mktmpdir do |directory|
      root = File.join(directory, "workspace")
      runtime = File.join(directory, "runtime")
      FileUtils.mkdir_p([File.join(root, "source"), runtime])
      read_only_file = File.join(root, "source", "protected.txt")
      runtime_file = File.join(runtime, "secret.txt")
      File.write(read_only_file, "protected")
      File.write(runtime_file, "secret")
      File.link(read_only_file, File.join(root, "write-alias.txt"))
      File.link(runtime_file, File.join(root, "read-alias.txt"))
      workspace = LittleGhost::Workspace.new(
        root:,
        paths: {source: "source", runtime: runtime}
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {root: :read_write, source: :read_only},
          runtime_paths: {runtime: :read_only},
          network: :inherit
        }
      )

      read_error = assert_raises(LittleGhost::ToolError) { sandbox.read("read-alias.txt") }
      write_error = assert_raises(LittleGhost::ToolError) { sandbox.write("write-alias.txt", "changed") }

      assert_includes read_error.message, "Multiply-linked"
      assert_includes write_error.message, "Multiply-linked"
      assert_equal "protected", File.read(read_only_file)
      assert_equal "secret", File.read(runtime_file)
    ensure
      workspace&.close
    end
  end
end
