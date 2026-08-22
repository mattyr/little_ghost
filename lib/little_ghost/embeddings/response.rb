# frozen_string_literal: true

module LittleGhost
  module Embeddings
    # Returns provider-neutral vectors in the same order as the request inputs.
    Response = Data.define(:vectors, :usage, :metadata) do
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
  end
end
