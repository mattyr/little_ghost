# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Bounded file and process output sizes applied by Sandbox tools.
    class Limits
      DEFAULTS = {
        read_bytes: 1_000_000,
        write_bytes: 1_000_000,
        list_entries: 10_000,
        output_bytes: 1_000_000
      }.freeze # :nodoc:

      # Returns +value+ unchanged or builds limits from a Hash.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise PolicyError, "sandbox limits must be a Hash" unless value.respond_to?(:to_h)

        new(**value.to_h.transform_keys(&:to_sym))
      end

      # Builds positive file and process output limits.
      def initialize(**values)
        unknown = values.keys - DEFAULTS.keys
        raise PolicyError, "unknown sandbox limits: #{unknown.join(", ")}" unless unknown.empty?

        DEFAULTS.merge(values).each do |name, value|
          value = Integer(value)
          raise PolicyError, "sandbox #{name} must be positive" unless value.positive?

          instance_variable_set("@#{name}", value)
        rescue ArgumentError, TypeError
          raise PolicyError, "sandbox #{name} must be an integer"
        end
        freeze
      end

      # Maximum bytes returned by one filesystem read.
      attr_reader :read_bytes
      # Maximum bytes accepted by one filesystem write.
      attr_reader :write_bytes
      # Maximum entries returned by one directory listing.
      attr_reader :list_entries
      # Maximum bytes captured from each child output stream.
      attr_reader :output_bytes
    end
  end
end
