# frozen_string_literal: true

module LittleGhost
  module Providers
    # Reports a bounded HTTP or network failure from a provider connection.
    class HTTPError < ProviderError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        @status = status
        @body = body
        super(message)
      end

      def retryable?
        status.nil? || status == 408 || status == 409 || status == 429 || status >= 500
      end
    end

    # Shared provider contract. Provider adapters implement #stream and may
    # override capability-sensitive request preparation.
    class Base
      # Streams normalized events for +request+.
      def stream(_request)
        raise AbstractMethodError, "#{self.class} must implement #stream"
      end

      # Applies provider-specific capability constraints before streaming.
      def prepare_request(request, capabilities:)
        request
      end

      # Returns provider capabilities derived from normalized metadata.
      def capabilities(metadata: {})
        ModelCapabilities.unknown
      end
    end
  end
end
