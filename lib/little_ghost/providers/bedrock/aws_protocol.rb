# frozen_string_literal: true

require "digest"
require "openssl"
require "time"
require "zlib"

module LittleGhost
  module Providers
    class Bedrock < Base
      # Signs AWS HTTP requests with Signature Version 4.
      class AwsSigV4 # :nodoc:
        def initialize(service:, region:, credentials:, clock: -> { Time.now.utc })
          @service = service
          @region = region
          @credentials = credentials
          @clock = clock
        end

        def headers(method:, uri:, headers:, body:)
          time = @clock.call.utc
          timestamp = time.strftime("%Y%m%dT%H%M%SZ")
          date = time.strftime("%Y%m%d")
          normalized = headers.to_h.transform_keys { |key| key.to_s.downcase }
            .merge("host" => host_header(uri), "x-amz-date" => timestamp)
          normalized["x-amz-security-token"] = @credentials.session_token if @credentials.session_token
          canonical_headers = normalized.sort.map { |key, value| "#{key}:#{value.to_s.strip.gsub(/\s+/, " ")}\n" }.join
          signed_headers = normalized.keys.sort.join(";")
          canonical_request = [method.to_s.upcase, canonical_path(uri), canonical_query(uri), canonical_headers,
            signed_headers, Digest::SHA256.hexdigest(body)].join("\n")
          scope = "#{date}/#{@region}/#{@service}/aws4_request"
          string_to_sign = ["AWS4-HMAC-SHA256", timestamp, scope, Digest::SHA256.hexdigest(canonical_request)].join("\n")
          signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key(date), string_to_sign)
          normalized.merge("authorization" => "AWS4-HMAC-SHA256 Credential=#{@credentials.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}")
        end

        private

        def signing_key(date)
          date_key = OpenSSL::HMAC.digest("SHA256", "AWS4#{@credentials.secret_access_key}", date)
          region_key = OpenSSL::HMAC.digest("SHA256", date_key, @region)
          service_key = OpenSSL::HMAC.digest("SHA256", region_key, @service)
          OpenSSL::HMAC.digest("SHA256", service_key, "aws4_request")
        end

        def canonical_path(uri)
          path = uri.path.empty? ? "/" : uri.path
          path.split("/", -1).map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
        end

        def canonical_query(uri)
          URI.decode_www_form(uri.query.to_s).sort.map { |key, value| "#{escape(key)}=#{escape(value)}" }.join("&")
        end

        def escape(value) = URI.encode_www_form_component(value).gsub("+", "%20")
        def host_header(uri) = (uri.default_port == uri.port) ? uri.host : "#{uri.host}:#{uri.port}"
      end

      # Incrementally decodes the AWS EventStream binary framing protocol.
      class EventStreamDecoder # :nodoc:
        DEFAULT_MAX_FRAME_BYTES = 16 * 1024 * 1024
        DEFAULT_MAX_HEADERS_BYTES = 128 * 1024

        def initialize(max_frame_bytes: DEFAULT_MAX_FRAME_BYTES, max_headers_bytes: DEFAULT_MAX_HEADERS_BYTES)
          @buffer = String.new(encoding: Encoding::BINARY)
          @max_frame_bytes = Integer(max_frame_bytes)
          @max_headers_bytes = Integer(max_headers_bytes)
        end

        def <<(chunk)
          @buffer << chunk.b
          events = []
          loop do
            break if @buffer.bytesize < 12

            total_length, headers_length, prelude_crc = @buffer.unpack("NNN")
            raise ProtocolError, "AWS EventStream frame length is invalid" if total_length < 16 || headers_length > total_length - 16
            raise ProtocolError, "AWS EventStream frame exceeds the configured limit" if total_length > @max_frame_bytes
            raise ProtocolError, "AWS EventStream headers exceed the configured limit" if headers_length > @max_headers_bytes
            break if @buffer.bytesize < total_length

            frame = @buffer.slice!(0, total_length)
            raise ProtocolError, "AWS EventStream prelude checksum is invalid" unless Zlib.crc32(frame.byteslice(0, 8)) == prelude_crc
            expected_crc = frame.byteslice(total_length - 4, 4).unpack1("N")
            raise ProtocolError, "AWS EventStream message checksum is invalid" unless Zlib.crc32(frame.byteslice(0, total_length - 4)) == expected_crc

            headers = decode_headers(frame.byteslice(12, headers_length))
            payload = frame.byteslice(12 + headers_length, total_length - headers_length - 16)
            events << [headers, payload]
          end
          events
        end

        def finish
          raise ProtocolError, "AWS EventStream ended with an incomplete frame" unless @buffer.empty?
        end

        private

        def decode_headers(bytes)
          offset = 0
          headers = {}
          while offset < bytes.bytesize
            name_length = bytes.getbyte(offset)
            offset += 1
            name = bytes.byteslice(offset, name_length)
            offset += name_length
            type = bytes.getbyte(offset)
            offset += 1
            case type
            when 0 then value = true
            when 1 then value = false
            when 2 then value = bytes.getbyte(offset).then {
              offset += 1
              _1
            }
            when 6, 7
              length = bytes.byteslice(offset, 2).unpack1("n")
              offset += 2
              value = bytes.byteslice(offset, length)
              offset += length
            else
              raise ProtocolError, "Unsupported AWS EventStream header type #{type}"
            end
            headers[name] = value
          end
          headers
        end
      end
    end
  end
end
