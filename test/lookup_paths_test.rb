# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class LookupPathsTest < Minitest::Test
  def test_configuration_defaults_to_application_lookup_roots
    configuration = LittleGhost::Configuration.new

    assert_equal ["app/prompts"], configuration.prompt_paths
    assert_equal ["app/skills"], configuration.skill_paths
  end

  def test_configuration_assignment_replaces_defaults_and_mutation_appends
    configuration = LittleGhost::Configuration.new
    configuration.prompt_paths = ["/custom/prompts"]
    configuration.skill_paths << "/shared/skills"

    assert_equal ["/custom/prompts"], configuration.prompt_paths
    assert_equal ["app/skills", "/shared/skills"], configuration.skill_paths
  end

  def test_runtime_resolves_relative_and_absolute_lookup_roots
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |custom_root|
        configuration = LittleGhost::Configuration.new(root: application_root)
        configuration.prompt_paths = ["prompts", File.join(custom_root, "prompts")]
        configuration.skill_paths = ["skills", File.join(custom_root, "skills")]

        runtime = LittleGhost::Runtime.new(configuration:)

        assert_equal [
          File.join(File.realpath(application_root), "prompts"),
          File.join(custom_root, "prompts")
        ], runtime.prompt_paths.map(&:path)
        assert_equal [
          File.join(File.realpath(application_root), "skills"),
          File.join(custom_root, "skills")
        ], runtime.skill_paths.map(&:path)
      end
    end
  end

  def test_runtime_paths_drive_prompt_and_skill_resolution
    Dir.mktmpdir do |application_root|
      Dir.mktmpdir do |shared_root|
        write(application_root, "app/prompts/example/system.erb", "application")
        write(application_root, "app/skills/review/SKILL.md", skill("application"))
        write(shared_root, "example/system.erb", "shared")
        write(shared_root, "review/SKILL.md", skill("shared"))
        configuration = LittleGhost::Configuration.new(root: application_root)
        configuration.prompt_paths << shared_root
        configuration.skill_paths << shared_root
        runtime = LittleGhost::Runtime.new(configuration:)

        resolver = LittleGhost::Templates::PromptResolver.new(paths: runtime.prompt_paths)
        catalog = LittleGhost::Skills::Catalog.new(paths: runtime.skill_paths)

        assert_equal "application", resolver.render("example/system")
        assert_equal "shared", catalog.fetch("review").instructions
      end
    end
  end

  private

  def skill(instructions)
    "---\nname: review\ndescription: Review code\n---\n#{instructions}"
  end

  def write(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
