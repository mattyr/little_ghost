# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "little_ghost/tools"

class ToolsTest < Minitest::Test
  def test_sandbox_exposes_direct_read_write_and_replace_operations
    Dir.mktmpdir do |directory|
      sandbox = unrestricted_sandbox(directory, writable: true)

      sandbox.write("note.txt", "hello world")
      sandbox.replace("note.txt", "world", "ghost")

      assert_equal "hello ghost", sandbox.read("note.txt")
      assert_includes LittleGhost::Tools::Filesystem.new(sandbox:).tools.map(&:tool_name), "replace_in_file"
    end
  end

  def test_sandbox_reads_lists_and_writes_within_root
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "input.txt"), "hello")
      tools = LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(directory, writable: true)).tools
      registry = LittleGhost::ToolRegistry.new(tools)

      assert_equal "hello", registry.fetch("read_file").execute({"path" => "input.txt"}).content
      assert_includes registry.fetch("list_files").execute({}).content, "input.txt"
      result = registry.fetch("write_file").execute({"path" => "output.txt", "content" => "world"})
      assert result.success?
      assert_equal "world", File.read(File.join(directory, "output.txt"))
    end
  end

  def test_sandbox_rejects_paths_outside_root
    Dir.mktmpdir do |directory|
      tool = LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(directory)).tools.first.new

      result = tool.execute({"path" => "../secret"})

      assert result.error?
    end
  end

  def test_sandbox_does_not_write_through_a_symlink
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        target = File.join(outside, "secret.txt")
        File.write(target, "original")
        File.symlink(target, File.join(directory, "link.txt"))
        registry = LittleGhost::ToolRegistry.new(
          LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(directory, writable: true)).tools
        )

        result = registry.fetch("write_file").execute({"path" => "link.txt", "content" => "changed"})

        assert result.error?
        assert_equal "original", File.read(target)
      end
    end
  end

  def test_sandbox_does_not_traverse_symlinked_directories
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "secret.txt"), "secret")
        File.symlink(outside, File.join(directory, "linked"))
        registry = LittleGhost::ToolRegistry.new(
          LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(directory, writable: true)).tools
        )

        assert registry.fetch("read_file").execute({"path" => "linked/secret.txt"}).error?
        assert registry.fetch("write_file").execute({"path" => "linked/new.txt", "content" => "changed"}).error?
        refute_path_exists File.join(outside, "new.txt")
      end
    end
  end

  def test_sandbox_rejects_fifo_without_blocking
    Dir.mktmpdir do |directory|
      path = File.join(directory, "pipe")
      assert system("mkfifo", path)
      registry = LittleGhost::ToolRegistry.new(
        LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(directory, writable: true)).tools
      )
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert registry.fetch("read_file").execute({"path" => "pipe"}).error?
      assert registry.fetch("write_file").execute({"path" => "pipe", "content" => "value"}).error?
      File.open(path, File::RDONLY | File::NONBLOCK) do
        assert registry.fetch("write_file").execute({
          "path" => "pipe", "content" => "value"
        }).error?
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at, :<, 1
    end
  end

  def test_sandbox_rejects_root_replacement
    Dir.mktmpdir do |parent|
      Dir.mktmpdir do |outside|
        root = File.join(parent, "root")
        moved = File.join(parent, "moved")
        Dir.mkdir(root)
        File.write(File.join(root, "value.txt"), "inside")
        File.write(File.join(outside, "value.txt"), "outside")
        registry = LittleGhost::ToolRegistry.new(
          LittleGhost::Tools::Filesystem.new(sandbox: unrestricted_sandbox(root)).tools
        )
        File.rename(root, moved)
        File.symlink(outside, root)

        assert registry.fetch("read_file").execute({"path" => "value.txt"}).error?
      end
    end
  end

  def test_shell_executes_argv_without_shell_expansion
    Dir.mktmpdir do |directory|
      tool = shell(directory).tool.new

      result = tool.execute({"command" => [RbConfig.ruby, "-e", "puts ARGV.first", "$(whoami)"]})
      output = JSON.parse(result.content)

      assert result.success?
      assert_equal "$(whoami)\n", output.fetch("stdout")
      assert output.fetch("success")
    end
  end

  def test_shell_times_out
    Dir.mktmpdir do |directory|
      tool = shell(directory, timeout: 0.05).tool.new

      result = tool.execute({"command" => [RbConfig.ruby, "-e", "sleep 1"]})

      assert result.error?
    end
  end

  def test_shell_timeout_includes_descendants_holding_output_open
    Dir.mktmpdir do |directory|
      shell = shell(directory, timeout: 0.05)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(LittleGhost::ToolError) do
        shell.run(["/bin/sh", "-c", "(sleep 2) &"])
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert_operator elapsed, :<, 1
    end
  end

  def test_shell_does_not_inherit_parent_environment_by_default
    Dir.mktmpdir do |directory|
      previous = ENV["LITTLE_GHOST_SECRET_TEST"]
      ENV["LITTLE_GHOST_SECRET_TEST"] = "credential"
      tool = shell(directory).tool.new

      result = tool.execute({"command" => [RbConfig.ruby, "-e", "print ENV['LITTLE_GHOST_SECRET_TEST'].to_s"]})

      assert_equal "", JSON.parse(result.content).fetch("stdout")
    ensure
      ENV["LITTLE_GHOST_SECRET_TEST"] = previous
    end
  end

  def test_sandbox_bounds_writes_and_directory_listings
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "one"), "1")
      File.write(File.join(directory, "two"), "2")
      registry = LittleGhost::ToolRegistry.new(
        LittleGhost::Tools::Filesystem.new(
          sandbox: unrestricted_sandbox(
            directory,
            writable: true,
            max_write_bytes: 2,
            max_list_entries: 1
          )
        ).tools
      )

      assert registry.fetch("write_file").execute({"path" => "out", "content" => "123"}).error?
      assert registry.fetch("list_files").execute({}).error?
    end
  end

  def test_unrestricted_sandbox_opens_after_a_lazy_workspace_creates_its_root
    Dir.mktmpdir do |directory|
      root = File.join(directory, "workspace")
      workspace = Class.new(LittleGhost::Workspace) do
        def open(run: nil)
          Dir.mkdir(root)
          self
        end
      end.new(root:)
      sandbox = LittleGhost::UnrestrictedSandbox.new(workspace:, writable: true)

      workspace.open
      sandbox.open
      sandbox.write("notes.txt", "ready")

      assert_equal "ready", sandbox.read("notes.txt")
    end
  end

  private

  def unrestricted_sandbox(directory, **options)
    LittleGhost::UnrestrictedSandbox.new(
      workspace: LittleGhost::Workspace.new(root: directory),
      **options
    )
  end

  def shell(directory, **options)
    sandbox = unrestricted_sandbox(directory)
    LittleGhost::Tools::Shell.new(sandbox:, **options)
  end
end
