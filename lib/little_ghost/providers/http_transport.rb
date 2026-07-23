# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module LittleGhost
  module Providers
    class HTTPError < ProviderError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        @status = status
        @body = body
        super(message)
      end

      def retryable?
        status.nil? || status == 408 || status == 409 || status == 429 || status >= 500
      end
    end

    class HTTPTransport
      DEFAULT_MAX_RESPONSE_BYTES = 50 * 1024 * 1024
      DEFAULT_MAX_ERROR_BODY_BYTES = 4 * 1024
      TRANSIENT_NETWORK_ERRORS = [
        Net::OpenTimeout,
        Net::ReadTimeout,
        Net::WriteTimeout,
        EOFError,
        SocketError,
        SystemCallError,
        IOError,
        OpenSSL::SSL::SSLError,
        Net::ProtocolError,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError
      ].freeze

      def initialize(
        base_url:,
        open_timeout:,
        read_timeout:,
        allow_insecure_http: false,
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        max_error_body_bytes: DEFAULT_MAX_ERROR_BODY_BYTES
      )
        @base_url = URI(base_url.end_with?("/") ? base_url : "#{base_url}/")
        unless %w[http https].include?(@base_url.scheme) && @base_url.host
          raise ConfigurationError, "Provider base_url must be an HTTP(S) URL"
        end
        if @base_url.scheme == "http" && !allow_insecure_http
          raise ConfigurationError, "Provider base_url must use HTTPS unless allow_insecure_http is enabled"
        end

        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_response_bytes = positive_integer(max_response_bytes, :max_response_bytes)
        @max_error_body_bytes = positive_integer(max_error_body_bytes, :max_error_body_bytes)
      end

      def stream(path:, headers:, body:, cancellation_token:, deadline: nil)
        return enum_for(__method__, path:, headers:, body:, cancellation_token:, deadline:) unless block_given?

        stream = Support::InterruptibleStream.new(cancellation_token:, deadline:) do |emit|
          uri = URI.join(@base_url.to_s, path.sub(%r{\A/}, ""))
          request = Net::HTTP::Post.new(uri)
          headers.each { |name, value| request[name] = value }
          request.body = body

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = remaining_timeout(deadline, @open_timeout)
          http.read_timeout = remaining_timeout(deadline, @read_timeout)
          http.write_timeout = remaining_timeout(deadline, @read_timeout)

          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              response_body = read_limited(response, @max_error_body_bytes)
              raise HTTPError.new(
                "Provider request failed with HTTP #{response.code}",
                status: response.code.to_i,
                body: response_body
              )
            end

            bytes_read = 0
            response.read_body do |chunk|
              bytes_read += chunk.bytesize
              raise ProtocolError, "Provider response exceeded #{@max_response_bytes} bytes" if bytes_read > @max_response_bytes

              emit.call(chunk)
            end
          end
        rescue *TRANSIENT_NETWORK_ERRORS => error
          raise HTTPError, "Provider request failed (#{error.class})"
        end
        stream.each { |chunk| yield chunk }
      end

      private

      def remaining_timeout(deadline, maximum)
        return maximum unless deadline

        remaining = deadline - Time.now
        raise DeadlineExceededError, "The run deadline was reached" unless remaining.positive?

        [remaining, maximum].min
      end

      def read_limited(response, limit)
        body = +""
        response.read_body do |chunk|
          remaining = limit - body.bytesize
          body << chunk.byteslice(0, remaining) if remaining.positive?
        end
        body
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end
    end
  end
end
