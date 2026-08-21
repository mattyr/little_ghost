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
        assert_equal File.realpath(File.join(second_root, "review", "SKILL.md")), catalog.fetch("review").source_path
      end
    end
  end

  def test_exposes_agent_paths_without_changing_physical_skill_access
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        first_directory = File.join(first_root, "review")
        second_directory = File.join(second_root, "deploy")
        FileUtils.mkdir_p(File.join(first_directory, "references"))
        Dir.mkdir(second_directory)
        File.write(
          File.join(first_directory, "SKILL.md"),
          "---\nname: review\ndescription: Review code\n---\nRead the guide."
        )
        File.write(File.join(first_directory, "references", "guide.md"), "Guide")
        File.write(
          File.join(second_directory, "SKILL.md"),
          "---\nname: deploy\ndescription: Deploy code\n---\nDeploy safely."
        )

        catalog = LittleGhost::Skills::Catalog.new(
          paths: [first_root, second_root],
          resource_root: "/skills"
        )

        review = catalog.fetch("review")
        assert_equal "/skills/review/SKILL.md", review.path
        assert_equal File.realpath(File.join(first_directory, "SKILL.md")), review.source_path
        assert_includes catalog.discovery_prompt, "<location>/skills/review/SKILL.md</location>"
        result = catalog.tool.new.execute({"skill_name" => "review"})
        assert_includes result.content, "Location: /skills/review/SKILL.md"
        assert_includes result.content, "/skills/review/references/guide.md"
        assert_equal "/skills/deploy/SKILL.md", catalog.fetch("deploy").path
      end
    end
  end

  def test_rejects_relative_resource_roots
    Dir.mktmpdir do |directory|
      error = assert_raises(ArgumentError) do
        LittleGhost::Skills::Catalog.new(paths: directory, resource_root: "skills")
      end

      assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
    end
  end

  def test_maps_skill_locations_to_workspace_references
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      FileUtils.mkdir_p(File.join(skill_directory, "references"))
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead the guide."
      )
      File.write(File.join(skill_directory, "references", "guide.md"), "Guide")

      workspace, sandbox = workspace_resources(directory)
      catalog = LittleGhost::Skills::Catalog.new(
        paths: directory,
        resource_root: "workspace://skills",
        workspace:,
        sandbox:
      )

      assert_equal "workspace://skills/review/SKILL.md", catalog.fetch("review").path
      result = catalog.tool.new.execute({"skill_name" => "review"})
      assert_includes result.content, "Location: workspace://skills/review/SKILL.md"
      assert_includes result.content, "workspace://skills/review/references/guide.md"
    ensure
      workspace&.close
    end
  end

  def test_agent_uses_the_runtime_workspace_resource_root
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead the guide."
      )
      runtime = Struct.new(
        :skill_paths, :skill_resource_root, :task_runner, :runtime_hooks, :code_mode_configuration
      ).new(
        [directory], "workspace://skills", LittleGhost::Support::TaskRunner.new, [], nil
      )
      workspace, sandbox = workspace_resources(directory)
      run = Struct.new(:runtime, :workspace, :sandbox).new(runtime, workspace, sandbox)
      agent_class = Class.new(LittleGhost::Agent) do
        system_prompt "Review carefully."
        skills
      end
      agent = agent_class.new(
        model: Object.new.extend(LittleGhost::ModelInterface),
        runtime:,
        run:
      )

      catalog = agent.tools.fetch("skills").catalog
      assert_equal "workspace://skills/review/SKILL.md", catalog.fetch("review").path
    ensure
      agent&.close
      workspace&.close
    end
  end

  def test_rejects_workspace_resource_roots_without_a_bound_workspace
    Dir.mktmpdir do |directory|
      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(paths: directory, resource_root: "workspace://skills")
      end

      assert_equal "workspace resource_root requires a Workspace and Sandbox", error.message
    end
  end

  def test_rejects_workspace_resource_roots_that_map_to_different_content
    Dir.mktmpdir do |directory|
      Dir.mktmpdir do |other|
        workspace, sandbox = workspace_resources(other)

        error = assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(
            paths: directory,
            resource_root: "workspace://skills",
            workspace:,
            sandbox:
          )
        end

        assert_equal "workspace resource_root must map to each skill path", error.message
      ensure
        workspace&.close
      end
    end
  end

  def test_rejects_writable_workspace_resource_roots
    Dir.mktmpdir do |directory|
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {skills: :read_write}, network: :inherit}
      )

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root must be tool-readable and read-only", error.message
    ensure
      workspace&.close
    end
  end

  def test_rejects_a_sandbox_bound_to_a_different_workspace
    Dir.mktmpdir do |directory|
      workspace, = workspace_resources(directory)
      other_workspace, sandbox = workspace_resources(directory)

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root requires the Sandbox bound to its Workspace", error.message
    ensure
      workspace&.close
      other_workspace&.close
    end
  end

  def test_rejects_writable_grants_nested_inside_a_workspace_resource_root
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead carefully."
      )
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory, mutable_skill: skill_directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {
          files: {skills: :read_only, mutable_skill: :read_write},
          network: :inherit
        }
      )

      error = assert_raises(LittleGhost::ConfigurationError) do
        LittleGhost::Skills::Catalog.new(
          paths: directory,
          resource_root: "workspace://skills",
          workspace:,
          sandbox:
        )
      end

      assert_equal "workspace resource_root must not contain writable file grants", error.message
    ensure
      workspace&.close
    end
  end

  def test_rejects_writable_grants_that_alias_a_skill_directory
    Dir.mktmpdir do |directory|
      skill_directory = File.join(directory, "review")
      writable_alias = Dir.mktmpdir
      Dir.mkdir(skill_directory)
      File.write(
        File.join(skill_directory, "SKILL.md"),
        "---\nname: review\ndescription: Review code\n---\nRead carefully."
      )
      workspace = LittleGhost::Workspace.new(
        root: Dir.mktmpdir,
        paths: {skills: directory},
        teardown: method(:remove_workspace_root)
      ).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {files: {skills: :read_only}, network: :inherit}
      )
      grants = sandbox.scope.process_grants
      writable_grant = LittleGhost::Sandbox::Mount.new(
        source: writable_alias,
        target: "/writable-skill-alias",
        access: :read_write
      )
      sandbox.define_singleton_method(:process_grants) { [*grants, writable_grant] }
      original_stat = File.method(:stat)
      physical_alias = File.realpath(writable_alias)

      error = File.stub(:stat, lambda { |path|
        [writable_alias, physical_alias].include?(path) ? original_stat.call(skill_directory) : original_stat.call(path)
      }) do
        assert_raises(LittleGhost::ConfigurationError) do
          LittleGhost::Skills::Catalog.new(
            paths: directory,
            resource_root: "workspace://skills",
            workspace:,
            sandbox:
          )
        end
      end

      assert_equal "workspace resource_root must not contain writable file grants", error.message
    ensure
      workspace&.close
      FileUtils.remove_entry(writable_alias) if writable_alias && Dir.exist?(writable_alias)
    end
  end

  def test_rejects_malformed_workspace_resource_roots
    Dir.mktmpdir do |directory|
      invalid = [
        "workspace://",
        "workspace:///skills",
        "workspace://skills/",
        "workspace://skills/../private",
        "workspace://skills//private",
        "workspace://skills\\private",
        "workspace://skills\0/private"
      ]

      invalid.each do |resource_root|
        error = assert_raises(ArgumentError) do
          LittleGhost::Skills::Catalog.new(paths: directory, resource_root:)
        end
        assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
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

  private

  def workspace_resources(skill_root)
    workspace = LittleGhost::Workspace.new(
      root: Dir.mktmpdir,
      paths: {skills: skill_root},
      teardown: method(:remove_workspace_root)
    ).open
    sandbox = LittleGhost::Sandboxes::Unrestricted.new(
      workspace:,
      policy: {files: {skills: :read_only}, network: :inherit}
    )
    [workspace, sandbox]
  end

  def remove_workspace_root(workspace:, **)
    FileUtils.remove_entry(workspace.root) if Dir.exist?(workspace.root)
  end
end
