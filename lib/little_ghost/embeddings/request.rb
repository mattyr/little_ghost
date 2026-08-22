# frozen_string_literal: true

module LittleGhost
  # Carries provider-neutral inputs and results for text embeddings.
  #
  # Applications usually call LittleGhost.embed. Provider adapters receive a
  # Request and return a Response without exposing provider response objects.
  module Embeddings
    DEFAULT_LIMITS = {
      max_inputs: 128,
      max_input_bytes: 64 * 1024,
      max_total_bytes: 1024 * 1024
    }.freeze # :nodoc:

    Request = Data.define(:inputs, :settings, :limits, :cancellation_token, :deadline) do # :nodoc:
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

    # Carries the validated inputs and controls for one embedding operation.
    #
    # LittleGhost builds this value for LittleGhost.embed and passes it to the
    # selected provider. Provider implementations may receive calls
    # concurrently. They must observe +cancellation_token+ and +deadline+ while
    # performing external work.
    class Request < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(inputs:, settings: {}, limits: {}, cancellation_token: Support::CancellationToken.new, deadline: nil) -> Request
      #
      # Validates and freezes one String or a nonempty Array of Strings.
      #
      # +settings+ contains trusted model settings. +limits+ may override the
      # input budgets:
      #
      # [+:max_inputs+]
      #   Number of input strings. Defaults to 128.
      # [+:max_input_bytes+]
      #   Bytes allowed in one input. Defaults to 64 KiB.
      # [+:max_total_bytes+]
      #   Bytes allowed across all inputs. Defaults to 1 MiB.
      #
      # Invalid shapes raise ArgumentError; inputs outside these budgets raise
      # UnsupportedInputError.

      ##
      # :attr_reader: inputs
      # Frozen input strings in caller order.

      ##
      # :attr_reader: settings
      # Frozen model settings chosen by trusted application code.

      ##
      # :attr_reader: limits
      # Frozen input budgets applied before LittleGhost retains the strings.

      ##
      # :attr_reader: cancellation_token
      # Token that stops the provider operation when cancellation is requested.

      ##
      # :attr_reader: deadline
      # Monotonic deadline for the provider operation, or +nil+.
    end
  end
end
