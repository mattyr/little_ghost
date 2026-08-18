# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Normalizes requested filesystem, process, environment, and child-network
    # controls into one immutable policy. Policy is a declaration, not proof of
    # isolation; the selected backend exposes #effective_policy and rejects
    # controls it cannot enforce.
    class Policy
      COMMON_KEYS = %i[
        files runtime_paths root_filesystem environment network
      ].freeze # :nodoc:
      ACCESS_MODES = %i[read_only read_write].freeze # :nodoc:
      ROOT_FILESYSTEM_MODES = %i[isolated read_only read_write].freeze # :nodoc:
      # Returns an existing policy or builds one from a Hash and keyword options.
      def self.coerce(value = nil, **options)
        return value if value.is_a?(self) && options.empty?
        values = value.nil? ? {} : value
        raise PolicyError, "sandbox policy must be a Hash or Sandbox::Policy" unless values.is_a?(Hash)

        new(**values.transform_keys(&:to_sym).merge(options))
      end

      # Builds a backend-independent policy from named Workspace paths.
      def initialize(
        files: {root: :read_only},
        runtime_paths: {},
        root_filesystem: :isolated,
        environment: {},
        network: nil
      )
        @files = normalize_paths(files, "files")
        @runtime_paths = normalize_paths(runtime_paths, "runtime_paths")
        @root_filesystem = enum!(root_filesystem, ROOT_FILESYSTEM_MODES, "root filesystem")
        @environment = EnvironmentPolicy.coerce(environment)
        @network = NetworkPolicy.coerce(network)
        freeze
      end

      # Named Workspace paths visible to tools and child processes.
      attr_reader :files
      # Named workspace paths visible only to sandboxed processes.
      attr_reader :runtime_paths
      # Requested host-root access: +:isolated+, +:read_only+, or +:read_write+.
      attr_reader :root_filesystem
      # Environment inheritance and explicit values.
      attr_reader :environment
      # Network policy, or +nil+ for a backend-specific secure default.
      attr_reader :network
      def workspace_writable? = files.fetch(:root, :read_only) == :read_write

      # Builds internal identity grants for a concrete Workspace.
      def process_grants(workspace) # :nodoc:
        file_mounts = files.map do |name, access|
          source = workspace_directory(workspace, name)
          Mount.new(source:, target: source, access:, protect_aliases: true)
        end
        process_mounts = runtime_paths.map do |name, access|
          source = workspace_directory(workspace, name)
          Mount.new(source:, target: source, access:, protect_aliases: true, tools: false)
        end
        (file_mounts + process_mounts).sort_by { |mount| -mount.target.length }.freeze
      end

      private

      def enum!(value, choices, label)
        value = value.to_sym
        raise PolicyError, "#{label} must be one of #{choices.map { |choice| ":#{choice}" }.join(", ")}" unless choices.include?(value)

        value
      end

      def normalize_paths(value, label)
        raise PolicyError, "sandbox #{label} must be a Hash" unless value.respond_to?(:each_pair)

        value.each_pair.to_h do |name, access|
          [name.to_sym, enum!(access, ACCESS_MODES, "#{label} access")]
        end.freeze
      end

      def workspace_directory(workspace, name)
        (name.to_sym == :root) ? workspace.root : workspace.path(name)
      end
    end
  end
end
