# frozen_string_literal: true

require_relative "../network"

module LittleGhost
  module Network
    # Exposes an application-managed proxy to an isolated sandbox without
    # claiming ownership of its lifecycle or attesting what it enforces. The
    # application owns proxy policy, credentials, readiness, logging, and cleanup.
    class ExternalGateway < Gateway
      # Builds a gateway around existing process-only workspace paths and a
      # physical proxy socket path. No path remapping is performed.
      def initialize(policy:, workspace:, runtime_paths:, proxy_mount_path:, environment: {}, validate: nil)
        super(policy:)
        @runtime_paths = Array(runtime_paths).map(&:to_sym).freeze
        raise PolicyError, "external gateway runtime_paths must not be empty" if @runtime_paths.empty?
        @roots = @runtime_paths.map { |name| (name == :root) ? workspace.root : workspace.path(name) }.freeze
        @proxy_mount_path = File.expand_path(proxy_mount_path).freeze
        unless @roots.any? { |root| @proxy_mount_path == root || @proxy_mount_path.start_with?("#{root}#{File::SEPARATOR}") }
          raise PolicyError, "external gateway proxy path must be inside a runtime path"
        end
        unless validate.nil? || validate.respond_to?(:call)
          raise PolicyError, "external gateway validator must be callable"
        end

        @environment = Sandbox::EnvironmentPolicy.coerce(environment).to_h
        @validator = validate
      end

      # Returns child-scoped proxy and trust variables.
      attr_reader :environment
      # Named process-only workspace paths used by the gateway.
      attr_reader :runtime_paths
      # Returns the proxy socket path visible inside the sandbox.
      attr_reader :proxy_mount_path

      # Pins application-managed mount roots without taking lifecycle ownership.
      def open(run: nil)
        @path_identities = @roots.to_h do |path|
          root = File.realpath(path)
          stat = File.stat(root)
          raise PolicyError, "external gateway runtime path must be a directory" unless stat.directory?

          [path, [root, stat.dev, stat.ino]]
        end.freeze
        self
      rescue Errno::ENOENT, Errno::EACCES
        raise DependencyError, "external gateway mount source is unavailable"
      end

      # Runs the application's readiness assertion before each child process.
      def validate!
        open unless @path_identities
        @roots.each do |path|
          root = File.realpath(path)
          stat = File.stat(root)
          unless [root, stat.dev, stat.ino] == @path_identities.fetch(path)
            raise DependencyError, "external gateway runtime path changed after opening"
          end
        end
        @validator&.call
        self
      rescue Errno::ENOENT, Errno::EACCES
        raise DependencyError, "external gateway runtime path changed after opening"
      end
    end
  end
end
