# frozen_string_literal: true

require "json"

module LittleGhost
  module CodeMode
    # Length-prefixed JSON framing shared by code-mode parent and child hosts.
    # Frames are bounded before allocation and parsing.
    module Protocol
      # Largest encoded JSON payload accepted by the protocol.
      MAX_FRAME_BYTES = 64 * 1024 * 1024
      # Raised for malformed or oversized frames.
      Error = Class.new(StandardError)

      module_function

      # Reads one complete frame from +io+, or returns +nil+ at clean EOF.
      def read(io)
        header = read_exactly(io, 4)
        return if header.nil?

        length = header.unpack1("N")
        raise Error, "Code-mode frame exceeds the size limit" if length > MAX_FRAME_BYTES

        JSON.parse(read_exactly(io, length) || raise(EOFError, "Code-mode frame ended early"))
      rescue JSON::ParserError => error
        raise Error, "Code-mode frame is not valid JSON: #{error.message}"
      end

      # Encodes +value+ and writes one complete frame to +io+.
      def write(io, value)
        io.write(dump(value))
        io.flush if io.respond_to?(:flush)
      end

      # Returns one encoded frame for +value+.
      def dump(value)
        payload = JSON.generate(value)
        raise Error, "Code-mode frame exceeds the size limit" if payload.bytesize > MAX_FRAME_BYTES

        [payload.bytesize].pack("N") << payload
      end

      # Removes and returns one complete frame from +buffer+, or returns +nil+
      # while more bytes are required.
      def extract!(buffer)
        return if buffer.bytesize < 4

        length = buffer.unpack1("N")
        raise Error, "Code-mode frame exceeds the size limit" if length > MAX_FRAME_BYTES
        return if buffer.bytesize < length + 4

        payload = buffer.byteslice(4, length)
        buffer.slice!(0, length + 4)
        JSON.parse(payload)
      rescue JSON::ParserError => error
        raise Error, "Code-mode frame is not valid JSON: #{error.message}"
      end

      def read_exactly(io, length)
        return "".b if length.zero?

        buffer = String.new(capacity: length, encoding: Encoding::BINARY)
        while buffer.bytesize < length
          chunk = io.read(length - buffer.bytesize)
          return if chunk.nil? && buffer.empty?
          raise EOFError, "Code-mode frame ended early" if chunk.nil?

          buffer << chunk
        end
        buffer
      end
      private_class_method :read_exactly
    end
  end
end
