# frozen_string_literal: true

module LittleGhost
  module Providers
    class SSEParser
      def initialize
        @buffer = +""
      end

      def <<(chunk)
        @buffer << chunk.to_s
        @buffer.gsub!("\r\n", "\n")
        events = []

        while (boundary = @buffer.index("\n\n"))
          frame = @buffer.slice!(0, boundary + 2)
          data = frame.lines.filter_map do |line|
            next unless line.start_with?("data:")

            line.delete_prefix("data:").sub(/\A /, "").chomp
          end
          events << data.join("\n") unless data.empty?
        end

        events
      end

      def finish
        return [] if @buffer.empty?

        self << "\n\n"
      end
    end
  end
end
