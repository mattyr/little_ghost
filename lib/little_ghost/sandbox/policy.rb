# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Normalizes backend-independent filesystem, process, environment, and
    # network controls into one immutable policy.
    class Policy
      COMMON_KEYS = %i[
        workspace_path workspace_access root_filesystem mounts environment
        network execution_scope
      ].freeze # :nodoc:
      ACCESS_MODES = %i[read_only read_write].freeze # :nodoc:
      ROOT_FILESYSTEM_MODES = %i[read_only read_write].freeze # :nodoc:
      EXECUTION_SCOPES = %i[command sandbox].freeze # :nodoc:

      # Returns an existing policy or builds one from a Hash and keyword options.
      def self.coerce(value = nil, root: nil, **options)
        return value if value.is_a?(self) && options.empty?
        values = value.nil? ? {} : value
        raise PolicyError, "sandbox policy must be a Hash or Sandbox::Policy" unless values.is_a?(Hash)

        new(**values.transform_keys(&:to_sym).merge(options), root:)
      end

      # Builds a backend-independent policy. Relative mount sources resolve
      # beneath +root+.
      def initialize(
        workspace_path: "/workspace",
        workspace_access: :read_only,
        root_filesystem: :read_only,
        mounts: [],
        environment: {},
        network: nil,
        execution_scope: :command,
        root: nil
      )
        @workspace_path = Mount.send(:normalize_virtual_path, workspace_path).freeze
        @workspace_access = enum!(workspace_access, ACCESS_MODES, "workspace access")
        @root_filesystem = enum!(root_filesystem, ROOT_FILESYSTEM_MODES, "root filesystem")
        @execution_scope = enum!(execution_scope, EXECUTION_SCOPES, "execution scope")
        @mounts = Array(mounts).map { |mount| Mount.coerce(mount, root:) }.freeze
        validate_mount_targets!
        @environment = EnvironmentPolicy.coerce(environment)
        @network = NetworkPolicy.coerce(network)
        freeze
      end

      # Absolute virtual path assigned to the workspace.
      attr_reader :workspace_path
      # Workspace access mode.
      attr_reader :workspace_access
      # Requested root-filesystem access mode.
      attr_reader :root_filesystem
      # Additional immutable virtual mounts.
      attr_reader :mounts
      # Environment inheritance and explicit values.
      attr_reader :environment
      # Network policy, or +nil+ for a backend-specific secure default.
      attr_reader :network
      # Process environment lifetime, +:command+ or +:sandbox+.
      attr_reader :execution_scope

      # Indicates that the workspace accepts filesystem mutations.
      def workspace_writable? = workspace_access == :read_write
      # Indicates that each execution gets a fresh environment.
      def command_scoped? = execution_scope == :command
      # Indicates that executions share one sandbox-lifetime environment.
      def sandbox_scoped? = execution_scope == :sandbox

      # Returns the virtual mounts including the workspace itself.
      def effective_mounts(workspace)
        [
          Mount.new(
            source: workspace.root,
            target: workspace_path,
            access: workspace_access,
            protect_aliases: true
          ),
          *mounts
        ].sort_by { |mount| -mount.target.length }.freeze
      end

      private

      def enum!(value, choices, label)
        value = value.to_sym
        raise PolicyError, "#{label} must be one of #{choices.map { |choice| ":#{choice}" }.join(", ")}" unless choices.include?(value)

        value
      end

      def validate_mount_targets!
        duplicates = mounts.group_by(&:target).select { |_, entries| entries.length > 1 }.keys
        raise PolicyError, "mount targets must be unique: #{duplicates.join(", ")}" unless duplicates.empty?
        if mounts.any? { |mount| mount.target == workspace_path }
          raise PolicyError, "an additional mount cannot replace the workspace target"
        end
      end
    end
  end
end
