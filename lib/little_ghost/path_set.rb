# frozen_string_literal: true

module LittleGhost
  # PathSet keeps prompt or skill lookup roots in deterministic search order. It
  # is immutable, so appending a path does not change a running configuration.
  class PathSet
    include Enumerable

    # The immutable Lookup::Root values in search order.
    attr_reader :paths

    # Accepts path strings and Lookup::Root objects.
    def initialize(paths = [])
      @paths = Array(paths).map { |path| path.is_a?(Lookup::Root) ? path : Lookup::Root.new(path:) }.freeze
    end

    # Yields each Lookup::Root in order.
    def each(&block)
      paths.each(&block)
    end

    # Copies the roots into a mutable array.
    def to_a
      paths.dup
    end

    # Appends +other+ in a new path set; neither input is mutated.
    def +(other)
      PathSet.new([*paths, *Array(other)])
    end
  end
end
