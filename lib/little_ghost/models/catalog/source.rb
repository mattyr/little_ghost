# frozen_string_literal: true

module LittleGhost
  module Models
    class Catalog
      # Interface for catalog refresh implementations.
      class Source
        DEFAULT_ATTRIBUTE_MERGE_STRATEGIES = {}.freeze # :nodoc:

        # Stable provenance name recorded for refreshed facts.
        attr_reader :name

        # Creates a source with its provenance +name+.
        def initialize(name:)
          @name = name.to_s.freeze
        end

        # Returns exceptional attribute merge strategies for records from this
        # source. Attributes replace older values unless an array is mapped to
        # +:union+.
        def attribute_merge_strategies = DEFAULT_ATTRIBUTE_MERGE_STRATEGIES

        # Returns normalized model records, optionally scoped to +target+.
        def refresh(target: nil)
          raise AbstractMethodError, "#{self.class} must implement #refresh"
        end
      end
    end
  end
end
