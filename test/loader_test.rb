# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"

class LoaderTest < Minitest::Test
  def test_eager_loads_agents_and_tools_with_namespaces
    Dir.mktmpdir do |root|
      write(root, "app/agents/loader_fixture/main_agent.rb", "module LoaderFixture; class MainAgent < LittleGhost::Agent; end; end")
      write(root, "app/tools/loader_fixture/echo_tool.rb", "module LoaderFixture; class EchoTool; end; end")

      loader = LittleGhost::Support::Loader.new(root:)
      loader.eager_load

      assert_equal LoaderFixture::MainAgent, loader.constant("LoaderFixture::MainAgent")
      assert_equal LoaderFixture::EchoTool, loader.constant("LoaderFixture::EchoTool")
    ensure
      Object.send(:remove_const, :LoaderFixture) if Object.const_defined?(:LoaderFixture, false)
    end
  end

  def test_rejects_duplicate_mappings_and_missing_expected_constants
    Dir.mktmpdir do |root|
      write(root, "app/agents/conflict.rb", "class Conflict; end")
      write(root, "app/tools/conflict.rb", "class Conflict; end")
      assert_raises(LittleGhost::Support::Loader::ConflictError) { LittleGhost::Support::Loader.new(root:).setup }
    end

    Dir.mktmpdir do |root|
      write(root, "app/agents/expected_agent.rb", "class DifferentAgent; end")
      assert_raises(LittleGhost::Support::Loader::ExpectedConstantError) { LittleGhost::Support::Loader.new(root:).eager_load }
    ensure
      Object.send(:remove_const, :DifferentAgent) if Object.const_defined?(:DifferentAgent, false)
      Object.send(:remove_const, :ExpectedAgent) if Object.const_defined?(:ExpectedAgent, false)
    end
  end

  def test_rejects_autoload_symlinks_that_escape_the_application_root
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        write(outside, "escaped_agent.rb", "class EscapedAgent; end")
        target = File.join(root, "app/agents/escaped_agent.rb")
        FileUtils.mkdir_p(File.dirname(target))
        File.symlink(File.join(outside, "escaped_agent.rb"), target)

        assert_raises(LittleGhost::Support::Loader::ConflictError) { LittleGhost::Support::Loader.new(root:).setup }
      end
    end
  end

  def test_rejects_load_directories_symlinked_outside_the_application_root
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |outside|
        write(outside, "escaped_agent.rb", "class EscapedAgent; end")
        FileUtils.mkdir_p(File.join(root, "app"))
        File.symlink(outside, File.join(root, "app/agents"))

        assert_raises(LittleGhost::Support::Loader::ConflictError) { LittleGhost::Support::Loader.new(root:).setup }
      end
    end
  end

  def test_rejects_root_relative_directories_that_escape_root
    Dir.mktmpdir do |root|
      assert_raises(ArgumentError) { LittleGhost::Support::Loader.new(root:, directories: ["../outside"]) }
    end
  end

  def test_preserves_name_errors_raised_while_loading_an_application_file
    Dir.mktmpdir do |root|
      write(root, "app/agents/broken_agent.rb", "MissingLoaderDependency")

      error = assert_raises(NameError) { LittleGhost::Support::Loader.new(root:).eager_load }

      assert_equal :MissingLoaderDependency, error.name
    ensure
      Object.send(:remove_const, :BrokenAgent) if Object.const_defined?(:BrokenAgent, false)
    end
  end

  def test_preserves_same_leaf_name_errors_from_an_unrelated_receiver
    Dir.mktmpdir do |root|
      write(root, "app/agents/broken_agent.rb", "module LoaderDependency; end; LoaderDependency::BrokenAgent")

      error = assert_raises(NameError) { LittleGhost::Support::Loader.new(root:).eager_load }

      assert_equal :BrokenAgent, error.name
      assert_equal LoaderDependency, error.receiver
    ensure
      Object.send(:remove_const, :BrokenAgent) if Object.const_defined?(:BrokenAgent, false)
      Object.send(:remove_const, :LoaderDependency) if Object.const_defined?(:LoaderDependency, false)
    end
  end

  private

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
