# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Normalizes a trusted Tool catalog for a guest language and rejects names
    # that would collide or shadow code-mode controls.
    class Catalog
      # Frozen normalized Tool definitions in declaration order.
      attr_reader :definitions

      # Normalizes trusted Tool +specifications+ with +normalize+. Names in
      # +reserved+ and names that collide after normalization are rejected.
      def initialize(specifications, normalize:, reserved: %w[exec wait stop])
        aliases = {}
        @definitions = Array(specifications).map do |specification|
          canonical_name = value(specification, :name).to_s
          name = normalize.call(canonical_name).to_s
          if reserved.include?(name)
            raise ConfigurationError, "Code-mode tool name #{canonical_name.inspect} conflicts with reserved tool #{name.inspect}"
          end
          if aliases.key?(name)
            raise ConfigurationError,
              "Code-mode tool names #{aliases.fetch(name).inspect} and #{canonical_name.inspect} both normalize to #{name.inspect}"
          end

          aliases[name] = canonical_name
          {
            "name" => name.freeze,
            "canonical_name" => canonical_name.freeze,
            "description" => value(specification, :description, "").to_s.freeze,
            "input_schema" => value(specification, :input_schema, {}).freeze,
            "specification" => specification
          }.freeze
        end.freeze
        @by_name = @definitions.to_h { |definition| [definition.fetch("name"), definition] }.freeze
      end

      # Returns the normalized definition for +name+.
      def fetch(name) = @by_name.fetch(name.to_s)
      # Indicates whether +name+ is present in the catalog.
      def key?(name) = @by_name.key?(name.to_s)

      private

      def value(specification, key, default = nil)
        return specification.fetch(key) if specification.key?(key)
        return specification.fetch(key.to_s) if specification.key?(key.to_s)
        return default unless default.nil?

        raise KeyError, "key not found: #{key.inspect}"
      end
    end
  end
end
