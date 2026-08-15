# frozen_string_literal: true

module LittleGhost
  class Sandbox
    # Declares whether a child inherits the host environment and which explicit
    # values are added or replaced.
    class EnvironmentPolicy
      # Returns +value+ unchanged or builds a policy from a Hash.
      def self.coerce(value)
        return value if value.is_a?(self)
        raise PolicyError, "sandbox environment must be a Hash" unless value.is_a?(Hash)

        if value.key?(:set) || value.key?("set") || value.key?(:inherit) || value.key?("inherit")
          values = value[:set] || value["set"] || {}
          inherit = value.fetch(:inherit, value.fetch("inherit", false))
        else
          values = value
          inherit = false
        end
        new(inherit:, values:)
      end

      # Builds an environment policy with explicit String-compatible +values+.
      def initialize(inherit: false, values: {})
        raise PolicyError, "sandbox environment values must be a Hash" unless values.is_a?(Hash)

        @inherit = !!inherit
        @values = values.to_h { |key, value| [String(key).freeze, String(value).freeze] }.freeze
        freeze
      end

      # Explicit child environment values.
      attr_reader :values

      # Indicates whether configured backends may inherit host values.
      def inherit? = @inherit
      # Returns the explicit child environment values.
      def to_h = values
    end
  end
end
