# frozen_string_literal: true

module LittleGhost
  module Embeddings
    Response = Data.define(:vectors, :usage, :metadata) do # :nodoc:
      # Validates finite, consistently sized numeric vectors and freezes them.
      def initialize(vectors:, usage: Usage.new, metadata: {})
        values = Array(vectors)
        unless !values.empty? && values.all? { |vector| vector.is_a?(Array) && !vector.empty? }
          raise ProtocolError, "Embedding provider returned no vectors"
        end
        dimensions = values.first.length
        unless values.all? { |vector| vector.length == dimensions && vector.all? { |number| number.is_a?(Numeric) && (!number.respond_to?(:finite?) || number.finite?) } }
          raise ProtocolError, "Embedding provider returned invalid vectors"
        end

        frozen_vectors = values.map { |vector| vector.map(&:to_f).freeze }.freeze
        super(vectors: frozen_vectors, usage:, metadata: metadata.to_h.merge(dimensions:).freeze)
      end

      # Number of numeric values in each vector.
      def dimensions = metadata.fetch(:dimensions)
    end

    # Carries validated embedding vectors without provider response objects.
    #
    # Vectors are finite, consistently sized, frozen, and ordered like the
    # corresponding Request inputs. LittleGhost raises ProtocolError instead of
    # returning an invalid or partial provider response.
    class Response < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(vectors:, usage: Usage.new, metadata: {}) -> Response
      #
      # Validates and freezes provider-neutral vectors, usage, and metadata.

      ##
      # :attr_reader: vectors
      # Frozen numeric vectors in request-input order.

      ##
      # :attr_reader: usage
      # Normalized provider usage for the operation.

      ##
      # :attr_reader: metadata
      # Frozen operation metadata, including +dimensions+.

      ##
      # :method: dimensions
      # Number of numeric values in each vector.
    end
  end
end
