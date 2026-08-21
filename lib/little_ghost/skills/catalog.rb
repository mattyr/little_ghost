# frozen_string_literal: true

require "yaml"
require "erb"
require_relative "resource_root"

module LittleGhost
  module Skills
    # A Catalog lets an agent discover focused instructions without putting every
    # skill in its prompt. The model sees short descriptions first and can load a
    # skill's full instructions when the task calls for them.
    #
    #   catalog = LittleGhost::Skills::Catalog.new(paths: ["app/skills"])
    #   catalog.names # => ["refund_policy", "search_orders"]
    #   catalog.discovery_prompt.include?("refund_policy") # => true
    #   catalog.tool # a LittleGhost::Tool that loads full instructions on demand
    #
    # Each immediate child directory may contain one +SKILL.md+ with YAML front
    # matter. Symbolic-link escapes, unsafe names, oversized files, and invalid
    # YAML are rejected or skipped before instructions reach a model. Optional
    # resource listings are limited by count and depth.
    #
    # === Choosing skill sources
    #
    # Skill files become model instructions, so keep configured roots under
    # application control and non-user-writable. The +allowed-tools+ field tells
    # the model what a skill expects; the Agent's Tool list and each Tool's
    # application checks still decide what can run. For a <tt>workspace://</tt>
    # resource root, the Catalog verifies the named read-only grant and rejects
    # direct writable aliases it can identify. LittleGhost cannot identify every
    # alias created by an outer container or mount namespace, so the application
    # must not expose the same files through another writable bind mount.
    class Catalog
      include Enumerable

      class InvalidSkillError < ConfigurationError; end # :nodoc:
      private_constant :InvalidSkillError

      DEFAULT_MAX_SKILLS = 1_000 # :nodoc:
      DEFAULT_MAX_FILE_BYTES = 1_000_000 # :nodoc:
      DEFAULT_MAX_RESOURCE_FILES = 20 # :nodoc:
      MAX_RESOURCE_DEPTH = 3 # :nodoc:
      RESOURCE_DIRECTORIES = %w[scripts references assets].freeze # :nodoc:
      SAFE_NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/ # :nodoc:

      # Loads valid skills immediately using the supplied safety limits.
      # +resource_root+ may be an absolute process-visible path. A
      # <tt>workspace://name</tt> reference also requires +workspace+ and
      # +sandbox+; it must resolve to every configured skill root through a
      # read-only file-tool grant.
      def initialize(
        paths:,
        max_skills: DEFAULT_MAX_SKILLS,
        max_file_bytes: DEFAULT_MAX_FILE_BYTES,
        max_resource_files: DEFAULT_MAX_RESOURCE_FILES,
        only: nil,
        resource_root: nil,
        workspace: nil,
        sandbox: nil
      )
        @paths = PathSet.new(paths)
        @max_skills = positive_integer(max_skills, :max_skills)
        @max_file_bytes = positive_integer(max_file_bytes, :max_file_bytes)
        @max_resource_files = positive_integer(max_resource_files, :max_resource_files)
        @only = Array(only).map(&:to_s).freeze if only
        @resource_root = ResourceRoot.normalize(resource_root)
        validate_workspace_resource_root!(workspace, sandbox)
        @skills = load_skills
        validate_workspace_resource_aliases!(sandbox)
      end

      # Yields each Skill in lookup order.
      def each(&block)
        @skills.each_value(&block)
      end

      # Finds the named Skill or raises ConfigurationError.
      def fetch(name)
        @skills.fetch(name.to_s) { raise ConfigurationError, "Unknown skill: #{name}" }
      end

      # Lists immutable skill names in lookup order.
      def names
        @skills.keys.freeze
      end

      # Produces the escaped, metadata-only prompt used for discovery.
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

      # Exposes full instructions on demand through a +skills+ Tool.
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

      # Formats one Skill, including allowed tools, compatibility, and bounded
      # resource paths.
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
        missing_root = @paths.find { |root| !Dir.exist?(root.path) && !root.boundary }
        raise Errno::ENOENT, missing_root.path if missing_root
        @paths.each do |root|
          next unless Dir.exist?(root.path)

          real_root = File.realpath(root.path)
          next if boundary_allows?(real_root, root.boundary)

          raise ConfigurationError, "Skill root escapes its configured boundary: #{root.path}"
        end

        paths = @paths.flat_map do |root|
          next [] unless Dir.exist?(root.path)

          Dir.glob(File.join(root.path, "*", "SKILL.md")).sort
        end
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
        root = @paths.find do |candidate|
          next false unless Dir.exist?(candidate.path)

          real_root = File.realpath(candidate.path)
          inside_root?(real_path, real_root) && boundary_allows?(real_root, candidate.boundary)
        end
        raise ConfigurationError, "Skill path escapes its configured root: #{path}" unless root
        root_path = File.realpath(root.path)
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
          name:, description:, instructions: match[2].strip,
          path: agent_path(real_path, root_path), source_path: real_path,
          allowed_tools:, compatibility:
        )
      rescue Psych::Exception => error
        raise InvalidSkillError, "Invalid skill front matter in #{path}: #{error.message}"
      end

      def inside_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def boundary_allows?(path, boundary)
        return true unless boundary

        boundary = File.realpath(boundary)
        inside_root?(path, boundary)
      end

      def skill_resources(skill)
        directory = File.dirname(skill.source_path)
        files = RESOURCE_DIRECTORIES.flat_map do |name|
          root = File.join(directory, name)
          next [] unless File.directory?(root) && !File.symlink?(root)

          resource_files(root, prefix: name)
        end.sort
        files.map! { |path| resource_path(skill, path) } if @resource_root
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

      def validate_workspace_resource_root!(workspace, sandbox)
        return unless @resource_root&.start_with?("workspace://")
        unless workspace && sandbox
          raise ConfigurationError, "workspace resource_root requires a Workspace and Sandbox"
        end
        unless sandbox.workspace.equal?(workspace)
          raise ConfigurationError, "workspace resource_root requires the Sandbox bound to its Workspace"
        end

        physical_root = File.realpath(workspace.resolve(@resource_root))
        source_roots = @paths.filter_map do |root|
          File.realpath(root.path) if Dir.exist?(root.path)
        end
        unless source_roots.all? { |source_root| source_root == physical_root }
          raise ConfigurationError, "workspace resource_root must map to each skill path"
        end
        unless sandbox.allows?(:filesystem_read, @resource_root) &&
            !sandbox.allows?(:filesystem_write, @resource_root)
          raise ConfigurationError, "workspace resource_root must be tool-readable and read-only"
        end
        grants = writable_tool_grants(sandbox)
        writable_inside_root = grants.any? do |grant|
          source = File.realpath(grant.source)
          source == physical_root || source.start_with?("#{physical_root}#{File::SEPARATOR}")
        end
        if writable_inside_root
          raise ConfigurationError, "workspace resource_root must not contain writable file grants"
        end
        @workspace_physical_root = physical_root
      rescue Errno::ENOENT, KeyError, ArgumentError => error
        raise ConfigurationError, "workspace resource_root is not available: #{error.message}"
      end

      def validate_workspace_resource_aliases!(sandbox)
        return unless @workspace_physical_root

        grants = writable_tool_grants(sandbox)
        protected_identities = protected_directory_identities
        aliased = grants.any? do |grant|
          stat = File.stat(grant.source)
          protected_identities.include?([stat.dev, stat.ino])
        end
        if aliased
          raise ConfigurationError, "workspace resource_root must not contain writable file grants"
        end
      rescue Errno::ENOENT, Errno::EACCES => error
        raise ConfigurationError, "workspace resource_root is not available: #{error.message}"
      end

      def writable_tool_grants(sandbox)
        grants = sandbox.respond_to?(:process_grants) ? sandbox.process_grants : sandbox.scope.process_grants
        grants.select { |grant| grant.tool_visible? && grant.writable? }
      end

      def protected_directory_identities
        directories = [@workspace_physical_root]
        @skills.each_value do |skill|
          skill_directory = File.dirname(skill.source_path)
          directories << skill_directory
          RESOURCE_DIRECTORIES.each do |name|
            resource_root = File.join(skill_directory, name)
            collect_resource_directories(resource_root, directories) if File.directory?(resource_root)
          end
        end
        directories.uniq.to_h do |directory|
          stat = File.stat(directory)
          [[stat.dev, stat.ino], true]
        end
      end

      def collect_resource_directories(directory, directories, depth = 0)
        return if depth >= MAX_RESOURCE_DEPTH || File.symlink?(directory)

        directories << directory
        Dir.children(directory).each do |name|
          child = File.join(directory, name)
          collect_resource_directories(child, directories, depth + 1) if File.directory?(child)
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
      end

      def agent_path(source_path, source_root)
        return source_path unless @resource_root

        relative = source_path.delete_prefix("#{source_root}#{File::SEPARATOR}")
        File.join(@resource_root, relative)
      end

      def resource_path(skill, relative)
        File.join(File.dirname(skill.path), relative)
      end
    end
  end
end
