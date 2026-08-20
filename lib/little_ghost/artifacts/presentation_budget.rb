# frozen_string_literal: true

module LittleGhost
  module Artifacts
    # Bounds transient media delivery without making Tool success depend on
    # delivery order. Overflowing content keeps its materialized reference but
    # is not inserted into the model conversation. # :nodoc:
    class PresentationBudget # :nodoc:
      MAX_COUNT = 4
      MAX_BYTES = 8 * 1024 * 1024

      def initialize
        @count = 0
        @bytes = 0
        @mutex = Mutex.new
      end

      def accept(content)
        blocks = Array(content)
        bytes = blocks.sum { |block| block_bytes(block) }
        @mutex.synchronize do
          return [].freeze if @count + blocks.length > MAX_COUNT
          return [].freeze if @bytes + bytes > MAX_BYTES

          @count += blocks.length
          @bytes += bytes
        end
        blocks
      end

      private

      def block_bytes(block)
        case block
        when Content::Text then String(block.text).bytesize
        when Content::Image, Content::Document then String(block.data).bytesize
        else 0
        end
      rescue TypeError
        0
      end
    end
  end
end
