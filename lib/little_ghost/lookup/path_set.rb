# frozen_string_literal: true

module LittleGhost
  module Lookup
    Root = Data.define(:path, :boundary) do
      def initialize(path:, boundary: nil)
        super(
          path: File.expand_path(path).freeze,
          boundary: boundary && File.expand_path(boundary).freeze
        )
      end
    end

    class PathSet
      include Enumerable

      attr_reader :paths

      def initialize(paths = [])
        @paths = Array(paths).map { |path| path.is_a?(Root) ? path : Root.new(path:) }.freeze
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
end
