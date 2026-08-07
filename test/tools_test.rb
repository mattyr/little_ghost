# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "little_ghost/tools"

class ToolsTest < Minitest::Test
  def test_filesystem_provider_exposes_writable_operations
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(unrestricted_sandbox(directory, writable: true))

      assert_equal %w[read_file list_files write_file replace_in_file], registry.names
      assert registry.fetch("write_file").execute({"path" => "note.txt", "content" => "hello"}).success?
      assert_equal "hello", registry.fetch("read_file").execute({"path" => "note.txt"}).content
      assert registry.fetch("replace_in_file").execute({
        "path" => "note.txt", "old_text" => "hello", "new_text" => "ghost"
      }).success?
      assert_equal "ghost", File.read(File.join(directory, "note.txt"))
    end
  end

  def test_filesystem_provider_omits_writes_for_a_read_only_sandbox
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(unrestricted_sandbox(directory))

      assert_equal %w[read_file list_files], registry.names
    end
  end

  def test_filesystem_provider_rejects_paths_outside_the_root
    Dir.mktmpdir do |directory|
      result = filesystem_registry(unrestricted_sandbox(directory)).fetch("read_file").execute({"path" => "../secret"})

      assert result.error?
    end
  end

  def test_filesystem_provider_does_not_follow_symlinks
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        target = File.join(outside, "secret.txt")
        File.write(target, "original")
        File.symlink(target, File.join(directory, "link.txt"))
        registry = filesystem_registry(unrestricted_sandbox(directory, writable: true))

        assert registry.fetch("write_file").execute({"path" => "link.txt", "content" => "changed"}).error?
        assert_equal "original", File.read(target)
      end
    end
  end

  def test_exclusive_filesystem_provider_marks_every_tool_exclusive
    Dir.mktmpdir do |directory|
      registry = filesystem_registry(unrestricted_sandbox(directory, writable: true), LittleGhost::Tools::Filesystem::Exclusive)

      assert registry.all?(&:exclusive?)
    end
  end

  def test_shell_uses_the_context_sandbox_without_shell_expansion
    Dir.mktmpdir do |directory|
      sandbox = unrestricted_sandbox(directory)
      registry = LittleGhost::ToolRegistry.new(
        [LittleGhost::Tools::Shell], binding: LittleGhost::Tool::Binding.new(sandbox:)
      )

      result = registry.fetch("shell").execute({"command" => [RbConfig.ruby, "-e", "puts ARGV.first", "$(whoami)"]})

      assert result.success?
      assert_equal "$(whoami)\n", JSON.parse(result.content).fetch("stdout")
    end
  end

  def test_shell_does_not_inherit_parent_environment
    Dir.mktmpdir do |directory|
      previous = ENV["LITTLE_GHOST_SECRET_TEST"]
      ENV["LITTLE_GHOST_SECRET_TEST"] = "credential"
      sandbox = unrestricted_sandbox(directory)
      registry = LittleGhost::ToolRegistry.new(
        [LittleGhost::Tools::Shell], binding: LittleGhost::Tool::Binding.new(sandbox:)
      )

      result = registry.fetch("shell").execute({"command" => [RbConfig.ruby, "-e", "print ENV['LITTLE_GHOST_SECRET_TEST'].to_s"]})

      assert_equal "", JSON.parse(result.content).fetch("stdout")
    ensure
      ENV["LITTLE_GHOST_SECRET_TEST"] = previous
    end
  end

  private

  def filesystem_registry(sandbox, provider = LittleGhost::Tools::Filesystem)
    LittleGhost::ToolRegistry.new([provider], binding: LittleGhost::Tool::Binding.new(sandbox:))
  end

  def unrestricted_sandbox(directory, **options)
    LittleGhost::UnrestrictedSandbox.new(
      workspace: LittleGhost::Workspace.new(root: directory),
      **options
    )
  end
end
