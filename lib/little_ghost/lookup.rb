# frozen_string_literal: true

module LittleGhost
  # Lookup holds path values shared by prompt and skill discovery.
  module Lookup
    # Root is an expanded lookup +path+ and an optional trusted +boundary+ it must stay
    # within after resolving symbolic links.
    Root = Data.define(:path, :boundary) do # :nodoc:
      def initialize(path:, boundary: nil)
        super(
          path: File.expand_path(path).freeze,
          boundary: boundary && File.expand_path(boundary).freeze
        )
      end
    end

    # Holds an expanded lookup path and the optional trusted boundary it must
    # remain within after symbolic links are resolved.
    class Root < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(path:, boundary: nil) -> Root
      #
      # Expands +path+ and the optional +boundary+ without resolving symbolic
      # links.

      ##
      # :attr_reader: path
      # The expanded lookup path.

      ##
      # :attr_reader: boundary
      # The expanded containment boundary, or +nil+ when none was supplied.
    end
  end
end
