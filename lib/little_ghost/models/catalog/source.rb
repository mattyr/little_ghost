# frozen_string_literal: true

module LittleGhost
  module Models
    class Catalog
      # Interface for catalog refresh implementations.
      class Source
        # Stable provenance name recorded for refreshed facts.
        attr_reader :name

        # Creates a source with its provenance +name+.
        def initialize(name:)
          @name = name.to_s.freeze
        end

        # Returns normalized model records, optionally scoped to +target+.
        def refresh(target: nil)
          raise AbstractMethodError, "#{self.class} must implement #refresh"
        end
      end
    end
  end
end
