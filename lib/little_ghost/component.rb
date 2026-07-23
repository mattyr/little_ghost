# frozen_string_literal: true

module LittleGhost
  class Component
    attr_reader :root, :loader, :prompt_paths

    def initialize(root:)
      @root = canonical_root(root)
      @loader = Support::Loader.new(root: @root)
      @prompt_paths = discover_prompt_paths.freeze
      freeze
    end

    private

    def canonical_root(value)
      path = File.realpath(File.expand_path(value))
      raise ArgumentError, "component root must be a directory" unless File.directory?(path)

      path.freeze
    rescue Errno::ENOENT
      raise ArgumentError, "component root must exist"
    end

    def discover_prompt_paths
      path = File.join(root, "app/prompts")
      return [] unless File.exist?(path) || File.symlink?(path)

      resolved = File.realpath(path)
      unless File.directory?(resolved) && inside_root?(resolved)
        raise Support::Loader::ConflictError, "Component prompt directory escapes component root: #{path}"
      end
      [Templates::Root.new(path: resolved, boundary: root)]
    rescue Errno::ENOENT
      raise Support::Loader::ConflictError, "Component prompt directory is invalid: #{path}"
    end

    def inside_root?(path)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end
  end
end
