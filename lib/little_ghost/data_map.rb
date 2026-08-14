# frozen_string_literal: true

module LittleGhost
  # DataMap holds JSON-compatible application data with indifferent key access.
  # It stores every key as a String while accepting String and Symbol keys for
  # lookup and mutation, including in nested maps.
  #
  #   state = DataMap.new(plan: {status: "active"})
  #   state.dig("plan", :status) # => "active"
  #   state.to_h                  # => {"plan" => {"status" => "active"}}
  #
  # State and metadata exposed by Sessions and RunContexts use DataMap so they
  # remain easy to work with in Ruby and portable across session stores. Values
  # are limited to JSON primitives, Arrays, and mappings. A mapping that
  # supplies both a String and Symbol form of the same key is ambiguous and
  # raises ArgumentError.
  class DataMap < Hash
    MAX_DEPTH = 100 # :nodoc:
    MAX_NODES = 100_000 # :nodoc:

    # Builds a deeply normalized map from +value+.
    def initialize(value = {})
      super()
      replace(value)
    end

    # Returns +value+ when it is already a DataMap, or normalizes a mapping.
    def self.coerce(value)
      return value if value.is_a?(self)

      new(value)
    end

    # Looks up +key+ after canonicalizing it to a String.
    def [](key) = super(normalize_key(key))

    # Stores +value+ under the canonical String form of +key+.
    def []=(key, value)
      validate_structure!(value)
      super(normalize_key(key), normalize_value(value))
    end
    alias_method :store, :[]=

    # Fetches +key+ with Hash#fetch's default and block behavior.
    def fetch(key, *defaults, &block) = super(normalize_key(key), *defaults, &block)

    # Checks for +key+ after canonicalizing it to a String.
    def key?(key) = super(normalize_key(key))
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    # Removes +key+ after canonicalizing it to a String.
    def delete(key, &block) = super(normalize_key(key), &block)

    # Traverses nested DataMaps with String or Symbol keys.
    def dig(key, *names) = super(normalize_key(key), *names)

    # Returns a normalized copy merged with +other+.
    def merge(other, &block)
      dup.merge!(other, &block)
    end

    # Merges +other+ after deeply normalizing its keys and values.
    def merge!(other)
      canonical_pairs(other).each do |key, value|
        self[key] = (block_given? && key?(key)) ? yield(key, self[key], value) : value
      end
      self
    end
    alias_method :update, :merge!

    # Replaces all entries with a deeply normalized copy of +other+.
    def replace(other)
      validate_structure!(other)
      pairs = canonical_pairs(other)
      clear
      pairs.each { |key, value| self[key] = value }
      self
    end

    # Returns a deep independent DataMap copy.
    def initialize_copy(other)
      super
      replace(other.to_h)
    end

    # Produces a deep ordinary Hash with canonical String keys.
    def to_h
      validate_structure!(self)
      each_with_object({}) { |(key, value), copy| copy[key] = plain_value(value) }
    end

    private

    def canonical_pairs(value)
      hash = Hash.try_convert(value)
      raise ArgumentError, "DataMap requires a mapping" unless hash

      seen = {}
      hash.map do |key, child|
        normalized = normalize_key(key)
        raise ArgumentError, "DataMap keys must not contain both String and Symbol forms" if seen[normalized]

        seen[normalized] = true
        [normalized, normalize_value(child)]
      end
    end

    def normalize_key(key)
      return key if key.is_a?(String)
      return key.to_s if key.is_a?(Symbol)

      raise ArgumentError, "DataMap keys must be Strings or Symbols"
    end

    def normalize_value(value)
      case value
      when DataMap, Hash
        self.class.new(value)
      when Array
        value.map { |child| normalize_value(child) }
      when String, Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ArgumentError, "DataMap values must be JSON-compatible" unless value.finite?

        value
      else
        raise ArgumentError, "DataMap values must be JSON-compatible"
      end
    end

    def plain_value(value)
      case value
      when DataMap
        value.to_h
      when Array
        value.map { |child| plain_value(child) }
      else
        value
      end
    end

    def validate_structure!(value)
      stack = [[:visit, value, 0]]
      ancestors = {}
      nodes = 0
      until stack.empty?
        action, current, depth = stack.pop
        if action == :leave
          ancestors.delete(current)
          next
        end

        nodes += 1
        raise ArgumentError, "DataMap is too large" if nodes > MAX_NODES
        next unless current.is_a?(Hash) || current.is_a?(Array)

        raise ArgumentError, "DataMap is nested too deeply" if depth >= MAX_DEPTH
        raise ArgumentError, "DataMap cannot contain cyclic values" if ancestors[current.object_id]

        ancestors[current.object_id] = true
        stack << [:leave, current.object_id, depth]
        Array(current.is_a?(Hash) ? current.values : current).reverse_each do |child|
          stack << [:visit, child, depth + 1]
        end
      end
    end
  end
end
