# frozen_string_literal: true

module LittleGhost
  # Network policy helpers used by sandbox backends. These controls apply only
  # to processes launched through the sandbox, not to providers or Ruby Tools.
  # A proxy enforces policy only when the Sandbox blocks every direct socket path.
  module Network
    # Normalized, headers-only request metadata passed to a trusted authorizer.
    class Request < Data.define(:method, :scheme, :host, :port, :path, :headers)
      # Builds normalized request metadata without a body.
      def initialize(method:, scheme:, host:, port:, path:, headers: {})
        super(
          method: String(method).upcase.freeze,
          scheme: String(scheme).downcase.freeze,
          host: String(host).downcase.freeze,
          port: Integer(port),
          path: String(path).freeze,
          headers: headers.to_h { |name, value| [String(name).downcase.freeze, String(value).freeze] }.freeze
        )
      end
    end

    # Trusted authorization result and tightly scoped upstream header changes.
    class Decision < Data.define(:allowed, :status, :reason, :set_headers, :remove_headers)
      HEADER_NAME = /\A[a-z0-9!#$%&'*+.^_`|~-]+\z/ # :nodoc:
      FORBIDDEN_MUTATIONS = %w[host connection content-length transfer-encoding upgrade proxy-connection].freeze # :nodoc:

      # Allows a request and optionally changes its upstream headers.
      def self.allow(set_headers: {}, remove_headers: [])
        new(allowed: true, status: 200, reason: nil, set_headers:, remove_headers:)
      end

      # Rejects a request with an HTTP +status+ and optional safe reason.
      def self.deny(status: 403, reason: nil)
        new(allowed: false, status:, reason:, set_headers: {}, remove_headers: [])
      end

      # Builds a normalized trusted authorization decision.
      def initialize(allowed:, status:, reason: nil, set_headers: {}, remove_headers: [])
        super(
          allowed: !!allowed,
          status: Integer(status),
          reason: reason&.to_s&.freeze,
          set_headers: normalize_headers(set_headers),
          remove_headers: Array(remove_headers).map { |name| normalize_header_name(name) }.uniq.freeze
        )
      end

      private

      def normalize_headers(headers)
        headers.to_h do |name, value|
          name = normalize_header_name(name)
          value = String(value)
          raise PolicyError, "network header values cannot contain control characters" if value.match?(/[\x00-\x1f\x7f]/)

          [name, value.freeze]
        end.freeze
      end

      def normalize_header_name(name)
        name = String(name).downcase
        if !HEADER_NAME.match?(name) || FORBIDDEN_MUTATIONS.include?(name) || name.start_with?("x-envoy-")
          raise PolicyError, "network authorizer returned an unsafe header mutation"
        end

        name.freeze
      end
    end

    # Lifecycle contract implemented by filtered-egress gateways. A Gateway is
    # one part of enforcement; the Sandbox must also prevent direct networking.
    class Gateway
      # Builds a gateway for a normalized network +policy+.
      def initialize(policy:)
        @policy = policy
      end

      # Network policy enforced by this gateway.
      attr_reader :policy

      # Starts run-scoped gateway resources.
      def open(run: nil) = self
      # Stops owned resources. Calling +close+ more than once must be safe.
      def close = nil
      # Fails closed when the gateway is no longer ready for a child process.
      def validate! = self
      # Returns child-process proxy and trust environment variables.
      def environment = {}.freeze
      # Returns read-only mounts required by child processes.
      def mounts = [].freeze
      # Returns an isolated container network name when applicable.
      def client_network = nil
    end
  end
end
