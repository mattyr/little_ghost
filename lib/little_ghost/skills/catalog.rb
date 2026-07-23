# frozen_string_literal: true

require "yaml"
require "erb"

module LittleGhost
  module Skills
    class Catalog
      include Enumerable

      class InvalidSkillError < ConfigurationError; end
      private_constant :InvalidSkillError

      DEFAULT_MAX_SKILLS = 1_000
      DEFAULT_MAX_FILE_BYTES = 1_000_000
      DEFAULT_MAX_RESOURCE_FILES = 20
      MAX_RESOURCE_DEPTH = 3
      RESOURCE_DIRECTORIES = %w[scripts references assets].freeze
      SAFE_NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

      def initialize(
        paths:,
        max_skills: DEFAULT_MAX_SKILLS,
        max_file_bytes: DEFAULT_MAX_FILE_BYTES,
        max_resource_files: DEFAULT_MAX_RESOURCE_FILES,
        only: nil
      )
        @paths = Array(paths).map { |path| File.realpath(path) }.freeze
        @max_skills = positive_integer(max_skills, :max_skills)
        @max_file_bytes = positive_integer(max_file_bytes, :max_file_bytes)
        @max_resource_files = positive_integer(max_resource_files, :max_resource_files)
        @only = Array(only).map(&:to_s).freeze if only
        @skills = load_skills
      end

      def each(&block)
        @skills.each_value(&block)
      end

      def fetch(name)
        @skills.fetch(name.to_s) { raise ConfigurationError, "Unknown skill: #{name}" }
      end

      def names
        @skills.keys.freeze
      end

      def discovery_prompt
        return "" if @skills.empty?

        lines = ["<available_skills>"]
        @skills.each_value do |skill|
          lines.concat([
            "<skill>",
            "<name>#{ERB::Util.html_escape(skill.name)}</name>",
            "<description>#{ERB::Util.html_escape(skill.description)}</description>",
            "<location>#{ERB::Util.html_escape(skill.path)}</location>",
            "</skill>"
          ])
        end
        lines << "</available_skills>"
        lines.join("\n")
      end

      def tool
        catalog = self
        Tool.define(
          name: "skills",
          description: <<~DESCRIPTION.strip,
            Activate a skill to load its full instructions.

            Use this tool to load the complete instructions for a skill listed in
            the available_skills section of your system prompt.
          DESCRIPTION
          input_schema: {
            type: "object",
            properties: {skill_name: {type: "string", description: "Name of the skill to activate."}},
            required: ["skill_name"],
            additionalProperties: false
          }
        ) do |input|
          catalog.format(catalog.fetch(input.fetch("skill_name")))
        rescue ConfigurationError => error
          raise ToolError, error.message
        end
      end

      def format(skill)
        parts = [skill.instructions]
        metadata = []
        metadata << "Allowed tools: #{skill.allowed_tools.join(", ")}" unless skill.allowed_tools.empty?
        metadata << "Compatibility: #{skill.compatibility}" if skill.compatibility
        metadata << "Location: #{skill.path}"
        parts << "\n---\n#{metadata.join("\n")}" unless metadata.empty?
        resources = skill_resources(skill)
        unless resources.empty?
          parts << "\nAvailable resources:\n#{resources.map { |path| "  #{path}" }.join("\n")}"
        end
        parts.join("\n")
      end

      private

      def load_skills
        paths = @paths.flat_map { |path| Dir.glob(File.join(path, "*", "SKILL.md")).sort }
        raise ConfigurationError, "Skill catalog exceeds #{@max_skills} skills" if paths.length > @max_skills

        paths.each_with_object({}) do |path, loaded|
          skill = begin
            parse(path)
          rescue InvalidSkillError, SystemCallError
            next
          end
          next if @only && !@only.include?(skill.name)

          loaded[skill.name] = skill
        end.freeze
      end

      def parse(path)
        real_path = File.realpath(path)
        root = @paths.find { |candidate| inside_root?(real_path, candidate) }
        raise ConfigurationError, "Skill path escapes its configured root: #{path}" unless root
        raise ConfigurationError, "Skill exceeds #{@max_file_bytes} bytes: #{path}" if File.size(real_path) > @max_file_bytes

        text = File.read(real_path, encoding: "UTF-8")
        raise InvalidSkillError, "Skill is not valid UTF-8: #{path}" unless text.valid_encoding?

        match = text.match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
        raise InvalidSkillError, "Skill must have YAML front matter: #{path}" unless match

        metadata = YAML.safe_load(match[1], permitted_classes: [], aliases: false) || {}
        raise InvalidSkillError, "Skill front matter must be a mapping: #{path}" unless metadata.is_a?(Hash)

        name = metadata["name"].to_s.strip
        description = metadata["description"].to_s.strip
        raise InvalidSkillError, "Skill name is required: #{path}" if name.empty?
        raise InvalidSkillError, "Skill description is required: #{path}" if description.empty?
        raise InvalidSkillError, "Skill name contains unsafe characters: #{path}" unless SAFE_NAME_PATTERN.match?(name)
        raise InvalidSkillError, "Skill description must be one line: #{path}" if description.match?(/[\r\n]/)

        allowed_tools = metadata["allowed-tools"] || metadata["allowed_tools"]
        allowed_tools = allowed_tools.split if allowed_tools.is_a?(String)
        allowed_tools = Array(allowed_tools).map(&:to_s).freeze
        compatibility = metadata["compatibility"]&.to_s
        Skill.new(
          name:, description:, instructions: match[2].strip, path: real_path,
          allowed_tools:, compatibility:
        )
      rescue Psych::Exception => error
        raise InvalidSkillError, "Invalid skill front matter in #{path}: #{error.message}"
      end

      def inside_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def skill_resources(skill)
        directory = File.dirname(skill.path)
        files = RESOURCE_DIRECTORIES.flat_map do |name|
          root = File.join(directory, name)
          next [] unless File.directory?(root) && !File.symlink?(root)

          resource_files(root, prefix: name)
        end.sort
        return files if files.length <= @max_resource_files

        [*files.first(@max_resource_files), "... (truncated at #{@max_resource_files} files)"]
      end

      def resource_files(directory, prefix:, depth: 0)
        return [] if depth >= MAX_RESOURCE_DEPTH

        Dir.children(directory).sort.flat_map do |name|
          path = File.join(directory, name)
          relative = "#{prefix}/#{name}"
          stat = File.lstat(path)
          if stat.directory? && !stat.symlink?
            resource_files(path, prefix: relative, depth: depth + 1)
          elsif stat.file?
            [relative]
          else
            []
          end
        rescue Errno::ENOENT, Errno::EACCES
          []
        end
      rescue Errno::ENOENT, Errno::EACCES
        []
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end
    end
  end
end
