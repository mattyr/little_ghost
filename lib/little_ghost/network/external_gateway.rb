# frozen_string_literal: true

require_relative "../network"

module LittleGhost
  module Network
    # Exposes an application-managed proxy to an isolated sandbox without
    # claiming ownership of the proxy's lifecycle.
    class ExternalGateway < Gateway
      # Builds a gateway around existing mounts and a proxy socket path.
      def initialize(policy:, mounts:, proxy_mount_path:, environment: {}, validate: nil)
        super(policy:)
        @mounts = Array(mounts).map { |mount| Sandbox::Mount.coerce(mount) }.freeze
        if @mounts.empty? || @mounts.any?(&:writable?)
          raise PolicyError, "external gateway mounts must be non-empty and read-only"
        end
        @proxy_mount_path = Sandbox::Mount.send(:normalize_virtual_path, proxy_mount_path).freeze
        unless @mounts.any? { |mount| mount.covers?(@proxy_mount_path) }
          raise PolicyError, "external gateway proxy path must be inside a declared mount"
        end
        unless validate.nil? || validate.respond_to?(:call)
          raise PolicyError, "external gateway validator must be callable"
        end

        @environment = Sandbox::EnvironmentPolicy.coerce(environment).to_h
        @validator = validate
      end

      # Returns child-scoped proxy and trust variables.
      attr_reader :environment
      # Returns application-managed files mounted read-only by the backend.
      attr_reader :mounts
      # Returns the proxy socket path visible inside the sandbox.
      attr_reader :proxy_mount_path

      # Pins application-managed mount roots without taking lifecycle ownership.
      def open(run: nil)
        @mount_identities = mounts.to_h do |mount|
          root = File.realpath(mount.source)
          stat = File.stat(root)
          raise PolicyError, "external gateway mount source must be a directory" unless stat.directory?

          [mount, [root, stat.dev, stat.ino]]
        end.freeze
        self
      rescue Errno::ENOENT, Errno::EACCES
        raise DependencyError, "external gateway mount source is unavailable"
      end

      # Runs the application's readiness assertion before each child process.
      def validate!
        open unless @mount_identities
        mounts.each do |mount|
          root = File.realpath(mount.source)
          stat = File.stat(root)
          unless [root, stat.dev, stat.ino] == @mount_identities.fetch(mount)
            raise DependencyError, "external gateway mount source changed after opening"
          end
        end
        @validator&.call
        self
      rescue Errno::ENOENT, Errno::EACCES
        raise DependencyError, "external gateway mount source changed after opening"
      end
    end
  end
end
