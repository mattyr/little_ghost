# frozen_string_literal: true

module LittleGhost
  class PathSet
    include Enumerable

    attr_reader :paths

    def initialize(paths = [])
      @paths = Array(paths).map { |path| path.is_a?(Lookup::Root) ? path : Lookup::Root.new(path:) }.freeze
    end

    def each(&block)
      paths.each(&block)
    end

    def to_a
      paths.dup
    end

    def +(other)
      PathSet.new([*paths, *Array(other)])
    end
  end
end
