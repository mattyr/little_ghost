# frozen_string_literal: true

require_relative "../network"
require_relative "../network/envoy_gateway"
require_relative "../network/external_gateway"

module LittleGhost
  class Sandbox
    # Shared policy and filesystem behavior for enforcing backends.
    class IsolatedBackend < Sandbox # :nodoc:
      def initialize(workspace:, policy: nil, profiles: {}, limits: {})
        super
        @effective_policy = policy_with_network_default(self.policy)
      end

      attr_reader :effective_policy

      def writable?
        capabilities.supports?(:filesystem_write) && effective_policy.effective_mounts(workspace).any?(&:writable?)
      end

      def read(path, context: nil) = default_scope.read(path, context:)
      def list(path = ".", context: nil) = default_scope.list(path, context:)
      def write(path, content, context: nil) = default_scope.write(path, content, context:)
      def replace(path, old_text, new_text, context: nil) = default_scope.replace(path, old_text, new_text, context:)

      private

      def default_scope
        @default_scope ||= Scope.new(sandbox: self)
      end

      def policy_with_network_default(configured)
        return configured if configured.network

        Policy.new(
          workspace_path: configured.workspace_path,
          workspace_access: configured.workspace_access,
          root_filesystem: configured.root_filesystem,
          mounts: configured.mounts,
          environment: configured.environment,
          network: :none,
          execution_scope: configured.execution_scope
        )
      end

      def execution_environment(additional, inherit_environment)
        inherit = effective_policy.environment.inherit? && inherit_environment
        [effective_policy.environment.to_h.merge(string_environment(additional)), inherit]
      end

      def string_environment(environment)
        environment.transform_keys(&:to_s).transform_values(&:to_s)
      end

      def execution_mounts(selected_scope)
        selected_scope&.validate!
        validate_mount_identities!
        mounts = selected_scope ? selected_scope.mounts : effective_mounts
        protect_execution_mounts(mounts)
      end

      def protect_execution_mounts(mounts)
        validate_mount_identities!
        protected_aliases = effective_mounts.select(&:protect_aliases?).select(&:read_only?).flat_map do |protected_mount|
          protected_root = canonical_mount_root(protected_mount)
          mounts.select(&:writable?).filter_map do |writable_mount|
            writable_root = canonical_mount_root(writable_mount)
            next unless contained_path?(protected_root, writable_root)

            relative = protected_root.delete_prefix(writable_root).delete_prefix(File::SEPARATOR)
            target = relative.empty? ? writable_mount.target : File.join(writable_mount.target, relative)
            Mount.new(
              source: protected_mount.source,
              target:,
              access: :read_only,
              protect_aliases: true,
              tools: protected_mount.tool_visible?
            )
          end
        end
        (mounts + protected_aliases)
          .group_by(&:target)
          .map { |_target, candidates| candidates.find(&:read_only?) || candidates.first }
          .sort_by { |mount| mount.target.length }
      end

      def capture_mount_identities!
        @mount_identities = effective_mounts.to_h do |mount|
          root = File.realpath(mount.source)
          stat = File.stat(root)
          [mount, [root.freeze, stat.dev, stat.ino].freeze]
        end.freeze
      rescue Errno::ENOENT, Errno::EACCES
        raise PolicyError, "sandbox mount source is unavailable"
      end

      def validate_mount_identities!
        capture_mount_identities! unless @mount_identities
        effective_mounts.each do |mount|
          expected = @mount_identities.fetch(mount)
          root = File.realpath(mount.source)
          stat = File.stat(root)
          unless [root, stat.dev, stat.ino] == expected
            raise PolicyError, "sandbox mount source changed after opening"
          end
        end
      rescue Errno::ENOENT, Errno::EACCES
        raise PolicyError, "sandbox mount source changed after opening"
      end

      def effective_mounts = effective_policy.effective_mounts(workspace)

      def canonical_mount_root(mount)
        @mount_identities.fetch(mount).first
      end

      def contained_path?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def open_gateway(run:, transport:, **defaults)
        return unless effective_policy.network.allowlist?

        declaration = effective_policy.network.gateway
        @gateway = case declaration
        when nil, :envoy, "envoy"
          Network::EnvoyGateway.new(policy: effective_policy.network, transport:, **defaults)
        when Hash
          values = declaration.transform_keys(&:to_sym)
          provider = values.delete(:provider) || :envoy
          case provider.to_sym
          when :envoy
            Network::EnvoyGateway.new(policy: effective_policy.network, transport:, **defaults.merge(values))
          when :external
            Network::ExternalGateway.new(policy: effective_policy.network, **values)
          else
            raise PolicyError, "unknown network gateway provider: #{provider.inspect}"
          end
        else
          if declaration.respond_to?(:call) && !declaration.is_a?(Network::Gateway)
            declaration.call(policy: effective_policy.network, transport:)
          else
            declaration
          end
        end
        unless @gateway.respond_to?(:open) && @gateway.respond_to?(:close)
          raise PolicyError, "network gateway must implement open and close"
        end

        @gateway.open(run:)
      end

      def close_gateway
        @gateway&.close
        @gateway = nil
      end
    end
  end
end
