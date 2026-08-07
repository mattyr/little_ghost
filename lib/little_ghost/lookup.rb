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
  end
end
