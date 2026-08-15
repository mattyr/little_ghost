# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Declares outbound connectivity for sandbox-launched processes. A network
    # policy does not apply to providers or arbitrary Ruby tools in the host.
    class NetworkPolicy
      MODES = %i[inherit none allowlist].freeze # :nodoc:
      INSPECTION_MODES = %i[connect http].freeze # :nodoc:

      # Returns +value+ unchanged or converts a mode or Hash to a policy.
      def self.coerce(value)
        return nil if value.nil?
        return value if value.is_a?(self)
        return new(mode: value) if value.is_a?(Symbol) || value.is_a?(String)
        raise PolicyError, "network policy must be a mode, Hash, or Sandbox::NetworkPolicy" unless value.is_a?(Hash)

        new(**value.transform_keys(&:to_sym))
      end

      # Builds an outbound policy. Enforcement remains the configured gateway's
      # responsibility.
      def initialize(mode:, allow: [], inspection: :connect, gateway: nil, authorizer: nil, forward_headers: [], mutation_headers: [])
        mode = mode.to_sym
        inspection = inspection.to_sym
        raise PolicyError, "network mode must be :inherit, :none, or :allowlist" unless MODES.include?(mode)
        unless INSPECTION_MODES.include?(inspection)
          raise PolicyError, "network inspection must be :connect or :http"
        end
        if mode != :allowlist && (!Array(allow).empty? || gateway || authorizer || !Array(forward_headers).empty? || !Array(mutation_headers).empty?)
          raise PolicyError, "network allow, gateway, authorizer, and header policy require mode :allowlist"
        end
        if inspection == :http && mode != :allowlist
          raise PolicyError, "HTTP inspection requires mode :allowlist"
        end
        if inspection == :http && !authorizer
          raise PolicyError, "HTTP inspection requires an authorizer"
        end
        if mode == :allowlist && Array(allow).empty?
          raise PolicyError, "network mode :allowlist requires at least one exact destination"
        end

        @mode = mode
        @allow = Array(allow).map { |endpoint| normalize_endpoint(endpoint) }.uniq.freeze
        @inspection = inspection
        @gateway = gateway
        @authorizer = authorizer
        @forward_headers = Array(forward_headers).map { |name| normalize_header_name(name) }.uniq.freeze
        @mutation_headers = Array(mutation_headers).map { |name| normalize_header_name(name) }.uniq.freeze
        freeze
      end

      # Connectivity mode: +:inherit+, +:none+, or +:allowlist+.
      attr_reader :mode
      # Normalized endpoints accepted by an allowlist gateway.
      attr_reader :allow
      # Inspection level requested from the gateway.
      attr_reader :inspection
      # Explicit gateway declaration, when supplied.
      attr_reader :gateway
      # Trusted request authorizer used by HTTP inspection, when supplied.
      attr_reader :authorizer
      # Header names the gateway may pass to an HTTP authorizer.
      attr_reader :forward_headers
      # Header names an HTTP authorizer may set on an upstream request.
      attr_reader :mutation_headers

      # Indicates unrestricted backend-provided connectivity.
      def inherit? = mode == :inherit
      # Indicates that outbound connectivity must be disabled.
      def none? = mode == :none
      # Indicates that outbound traffic must pass an allowlist gateway.
      def allowlist? = mode == :allowlist

      # Policies compare by their normalized enforcement declaration.
      def ==(other)
        other.is_a?(self.class) &&
          [mode, allow, inspection, gateway, authorizer, forward_headers, mutation_headers] ==
            [other.mode, other.allow, other.inspection, other.gateway, other.authorizer,
              other.forward_headers, other.mutation_headers]
      end

      alias_method :eql?, :==

      # Hashes the normalized enforcement declaration.
      def hash = [mode, allow, inspection, gateway, authorizer, forward_headers, mutation_headers].hash

      private

      def normalize_endpoint(endpoint)
        value = String(endpoint).strip.downcase
        raise PolicyError, "network allowlist entries cannot be empty" if value.empty?
        raise PolicyError, "network allowlist entries cannot contain whitespace" if value.match?(/\s/)

        value.freeze
      end

      def normalize_header_name(name)
        value = String(name).downcase
        unless value.match?(/\A[a-z0-9][a-z0-9-]*\z/)
          raise PolicyError, "forwarded network header names must be lowercase HTTP tokens"
        end

        value.freeze
      end
    end
  end
end
