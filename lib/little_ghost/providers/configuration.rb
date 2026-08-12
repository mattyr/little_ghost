# frozen_string_literal: true

module LittleGhost
  module Providers
    # Holds trusted provider connection settings independently from model
    # profiles. Connection names and option keys are normalized to strings, and
    # the resulting mapping is immutable.
    class Configuration
      # Normalized provider connections keyed by application-defined name.
      attr_reader :connections

      # Copies and freezes +connections+ so callers may safely reuse their input.
      def initialize(connections = {})
        unless connections.is_a?(Hash)
          raise ConfigurationError, "providers must be a mapping"
        end

        @connections = normalize(connections).freeze
        validate!
        freeze
      end

      # Returns credentials merged into +configuration+ when +provider+ is
      # constructed with +adapter+. Subclasses may resolve secrets lazily here.
      # The base implementation adds no credentials.
      def credentials(provider:, adapter:, configuration:)
        {}
      end

      private

      def normalize(connections)
        connections.to_h do |name, options|
          unless options.is_a?(Hash)
            raise ConfigurationError, "providers.#{name} must be a mapping"
          end

          normalized = options.to_h { |key, value| [key.to_s, deep_copy(value)] }
          normalized["adapter"] = normalized["adapter"].to_s if normalized.key?("adapter")
          [name.to_s, deep_freeze(normalized)]
        end
      end

      def deep_copy(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, deep_copy(child)] }
        when Array
          value.map { |child| deep_copy(child) }
        when String
          value.dup
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |child| deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        when String
          value.freeze
        end
        value.freeze if value.is_a?(Hash) || value.is_a?(Array)
        value
      end

      def validate!
        connections.each do |name, options|
          if options["adapter"].to_s.empty?
            raise ConfigurationError, "providers.#{name}.adapter is required"
          end
        end
      end
    end
  end
end
