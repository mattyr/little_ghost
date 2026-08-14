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
    alias_method :store_raw_value, :[]=
    private :store_raw_value

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
      plain_value(self)
    end

    private

    def canonical_pairs(value, normalize_values: true)
      hash = Hash.try_convert(value)
      raise ArgumentError, "DataMap requires a mapping" unless hash

      seen = {}
      hash.map do |key, child|
        normalized = normalize_key(key)
        raise ArgumentError, "DataMap keys must not contain both String and Symbol forms" if seen[normalized]

        seen[normalized] = true
        [normalized, normalize_values ? normalize_value(child) : child]
      end
    end

    def normalize_key(key)
      return key if key.is_a?(String)
      return key.to_s if key.is_a?(Symbol)

      raise ArgumentError, "DataMap keys must be Strings or Symbols"
    end

    def normalize_value(value)
      return normalize_scalar(value) unless container?(value)

      copy = container_copy(value)
      stack = [[:visit, value, copy]]
      ancestors = {}
      until stack.empty?
        action, current, target = stack.pop
        if action == :leave
          ancestors.delete(current)
          next
        end

        raise ArgumentError, "DataMap cannot contain cyclic values" if ancestors[current.object_id]

        ancestors[current.object_id] = true
        stack << [:leave, current.object_id, nil]
        if current.is_a?(Hash)
          canonical_pairs(current, normalize_values: false).reverse_each do |key, child|
            child_copy = container?(child) ? container_copy(child) : normalize_scalar(child)
            target.send(:store_raw_value, key, child_copy)
            stack << [:visit, child, child_copy] if container?(child)
          end
        else
          current.each_with_index do |child, index|
            child_copy = container?(child) ? container_copy(child) : normalize_scalar(child)
            target[index] = child_copy
            stack << [:visit, child, child_copy] if container?(child)
          end
        end
      end

      copy
    end

    def plain_value(value)
      return value unless container?(value)

      copy = value.is_a?(Array) ? [] : {}
      stack = [[:visit, value, copy]]
      ancestors = {}
      until stack.empty?
        action, current, target = stack.pop
        if action == :leave
          ancestors.delete(current)
          next
        end

        raise ArgumentError, "DataMap cannot contain cyclic values" if ancestors[current.object_id]

        ancestors[current.object_id] = true
        stack << [:leave, current.object_id, nil]
        if current.is_a?(Hash)
          canonical_pairs(current, normalize_values: false).each do |key, child|
            child_copy = container?(child) ? plain_container_copy(child) : normalize_scalar(child)
            target[key] = child_copy
            stack << [:visit, child, child_copy] if container?(child)
          end
        else
          current.each_with_index do |child, index|
            child_copy = container?(child) ? plain_container_copy(child) : normalize_scalar(child)
            target[index] = child_copy
            stack << [:visit, child, child_copy] if container?(child)
          end
        end
      end

      copy
    end

    def container?(value)
      value.is_a?(Hash) || value.is_a?(Array)
    end

    def container_copy(value)
      value.is_a?(Array) ? [] : self.class.new
    end

    def plain_container_copy(value)
      value.is_a?(Array) ? [] : {}
    end

    def normalize_scalar(value)
      case value
      when String, Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ArgumentError, "DataMap values must be JSON-compatible" unless value.finite?

        value
      else
        raise ArgumentError, "DataMap values must be JSON-compatible"
      end
    end
  end
end
