# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class SkillsTest < Minitest::Test
  def test_discovers_and_loads_skill_instructions
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(File.join(skill_directory, "SKILL.md"), <<~MARKDOWN)
        ---
        name: review
        description: Review code carefully
        allowed-tools: Read Grep
        compatibility: Ruby 3.3+
        ---
        Read every changed file.
      MARKDOWN
      FileUtils.mkdir_p(File.join(skill_directory, "references", "nested"))
      File.write(File.join(skill_directory, "references", "nested", "guide.md"), "Guide")

      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      assert_equal ["review"], catalog.names
      assert_includes catalog.discovery_prompt, "<name>review</name>"
      assert_includes catalog.discovery_prompt, "<description>Review code carefully</description>"
      result = catalog.tool.new.execute({"skill_name" => "review"})
      assert_includes result.content, "Read every changed file."
      assert_includes result.content, "Allowed tools: Read, Grep"
      assert_includes result.content, "Compatibility: Ruby 3.3+"
      assert_includes result.content, "Location: #{File.realpath(File.join(skill_directory, "SKILL.md"))}"
      assert_includes result.content, "references/nested/guide.md"
      assert_equal ["skill_name"], catalog.tool.input_schema.fetch("required")
    end
  end

  def test_skips_malformed_skills_without_hiding_valid_siblings
    Dir.mktmpdir do |directory|
      skills = {
        "valid" => "---\nname: valid\ndescription: Valid skill\n---\nUseful instructions",
        "missing-front-matter" => "instructions",
        "malformed-yaml" => "---\nname: [\ndescription: Broken YAML\n---\nBroken",
        "invalid-name" => "---\nname: invalid/name\ndescription: Unsafe name\n---\nBroken"
      }
      skills.each do |name, contents|
        skill_directory = File.join(directory, name)
        Dir.mkdir(skill_directory)
        File.write(File.join(skill_directory, "SKILL.md"), contents)
      end

      catalog = LittleGhost::Skills::Catalog.new(paths: directory)

      assert_equal ["valid"], catalog.names
      assert_equal "Useful instructions", catalog.fetch("valid").instructions
    end
  end

  def test_skips_an_unreadable_skill_without_hiding_valid_siblings
    Dir.mktmpdir do |directory|
      %w[valid unreadable].each do |name|
        skill_directory = File.join(directory, name)
        Dir.mkdir(skill_directory)
        File.write(
          File.join(skill_directory, "SKILL.md"),
          "---\nname: #{name}\ndescription: #{name}\n---\nInstructions"
        )
      end
      unreadable_path = File.realpath(File.join(directory, "unreadable", "SKILL.md"))
      original_read = File.method(:read)

      catalog = File.stub(:read, lambda { |path, *args, **options|
        raise Errno::EACCES, path if path == unreadable_path

        original_read.call(path, *args, **options)
      }) do
        LittleGhost::Skills::Catalog.new(paths: directory)
      end

      assert_equal ["valid"], catalog.names
    end
  end

  def test_catalog_skill_limit_counts_invalid_entries
    Dir.mktmpdir do |directory|
      2.times do |index|
        skill_directory = File.join(directory, "invalid-#{index}")
        Dir.mkdir(skill_directory)
        File.write(File.join(skill_directory, "SKILL.md"), "instructions")
      end

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(paths: directory, max_skills: 1)
      end

      assert_equal "Skill catalog exceeds 1 skills", error.message
    end
  end

  def test_later_paths_override_duplicate_skill_names
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        [
          [first_root, "First instructions"],
          [second_root, "Second instructions"]
        ].each do |root, instructions|
          directory = File.join(root, "review")
          Dir.mkdir(directory)
          File.write(
            File.join(directory, "SKILL.md"),
            "---\nname: review\ndescription: Review code\n---\n#{instructions}"
          )
        end

        catalog = LittleGhost::Skills::Catalog.new(paths: [first_root, second_root])

        assert_equal "Second instructions", catalog.fetch("review").instructions
        assert_equal File.realpath(File.join(second_root, "review", "SKILL.md")), catalog.fetch("review").path
      end
    end
  end

  def test_rejects_skill_symlinks_that_escape_the_catalog
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |outside|
        outside_skill = File.join(outside, "SKILL.md")
        File.write(outside_skill, "---\nname: escaped\ndescription: Escaped\n---\nDo things")
        skill_directory = File.join(directory, "escaped")
        Dir.mkdir(skill_directory)
        File.symlink(outside_skill, File.join(skill_directory, "SKILL.md"))

        assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(paths: directory)
        end
      end
    end
  end
end
