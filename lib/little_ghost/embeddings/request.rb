# frozen_string_literal: true

module LittleGhost
  # Provider-neutral contracts for creating numeric text embeddings.
  module Embeddings
    DEFAULT_LIMITS = {
      max_inputs: 128,
      max_input_bytes: 64 * 1024,
      max_total_bytes: 1024 * 1024
    }.freeze # :nodoc:

    # Carries one bounded embedding operation.
    Request = Data.define(:inputs, :settings, :limits, :cancellation_token, :deadline) do
      # Validates configured budgets before copying retained input strings.
      def initialize(inputs:, settings: {}, limits: {}, cancellation_token: Support::CancellationToken.new, deadline: nil)
        values = inputs.is_a?(String) ? [inputs] : inputs
        unless values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(String) && !value.empty? }
          raise ArgumentError, "inputs must be a nonempty String or Array of nonempty Strings"
        end
        raise ArgumentError, "settings must be a mapping" unless settings.respond_to?(:to_h)
        raise ArgumentError, "limits must be a mapping" unless limits.respond_to?(:to_h)

        configured_limits = DEFAULT_LIMITS.merge(limits.to_h.transform_keys(&:to_sym))
        configured_limits.transform_values! { |value| Integer(value) }
        unless configured_limits.values.all?(&:positive?)
          raise ArgumentError, "embedding limits must be positive integers"
        end
        if values.length > configured_limits.fetch(:max_inputs)
          raise UnsupportedInputError, "Embedding input count exceeds the configured limit"
        end
        total_bytes = 0
        values.each do |value|
          bytes = value.bytesize
          if bytes > configured_limits.fetch(:max_input_bytes)
            raise UnsupportedInputError, "An embedding input exceeds the configured byte limit"
          end
          total_bytes += bytes
          if total_bytes > configured_limits.fetch(:max_total_bytes)
            raise UnsupportedInputError, "Embedding inputs exceed the configured aggregate byte limit"
          end
        end

        super(
          inputs: values.map { |value| value.dup.freeze }.freeze,
          settings: settings.to_h.transform_keys(&:to_sym).freeze,
          limits: configured_limits.freeze,
          cancellation_token:,
          deadline:
        )
      end
    end
  end
end
