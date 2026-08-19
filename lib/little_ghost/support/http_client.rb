# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module LittleGhost
  module Support
    # HTTPClient gives integrations a shared, bounded streaming HTTP layer.
    # It applies cancellation, deadlines, timeouts, and response-size limits while
    # yielding response chunks as they arrive.
    #
    # === HTTPS defaults
    #
    # HTTPS is required by default. Enabling +allow_insecure_http+ can expose API
    # keys and model content in transit; use it only with a local
    # development endpoint.
    class HTTPClient
      # Default upper bound for a complete provider response (50 MiB).
      DEFAULT_MAX_RESPONSE_BYTES = 50 * 1024 * 1024
      DEFAULT_MAX_ERROR_BODY_BYTES = 4 * 1024 # :nodoc:
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
      ].freeze # :nodoc:

      # Configures +base_url+ with connection, read, and response
      # size limits.
      def initialize(
        base_url: nil,
        open_timeout: 10,
        read_timeout: 120,
        allow_insecure_http: false,
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        max_error_body_bytes: DEFAULT_MAX_ERROR_BODY_BYTES
      )
        if base_url
          @base_url = URI(base_url.end_with?("/") ? base_url : "#{base_url}/")
          validate_uri!(@base_url, allow_insecure_http:)
        end

        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @allow_insecure_http = allow_insecure_http
        @max_response_bytes = positive_integer(max_response_bytes, :max_response_bytes)
        @max_error_body_bytes = positive_integer(max_error_body_bytes, :max_error_body_bytes)
      end

      # Posts +body+ and yields response chunks until completion.
      #
      # Cancellation and +deadline+ interrupt the request. Without a block, this
      # method returns an Enumerator.
      def stream(path:, headers:, body:, cancellation_token:, deadline: nil)
        return enum_for(__method__, path:, headers:, body:, cancellation_token:, deadline:) unless block_given?
        raise ConfigurationError, "HTTP client requires base_url for streaming" unless @base_url

        stream = Support::InterruptibleStream.new(cancellation_token:, deadline:) do |emit|
          uri = URI.join(@base_url.to_s, path.sub(%r{\A/}, ""))
          each_chunk(
            uri:,
            method: :post,
            headers:,
            body:,
            deadline:,
            allow_insecure_http: @allow_insecure_http,
            label: "Provider"
          ) { |chunk| emit.call(chunk) }
        end
        stream.each { |chunk| yield chunk }
      end

      # Executes a bounded request and returns the complete response body.
      def request(uri:, method: :get, headers: {}, body: nil, allow_insecure_http: false,
        cancellation_token: nil, deadline: nil)
        response_body = +""
        each_chunk(
          uri:,
          method:,
          headers:,
          body:,
          cancellation_token:,
          deadline: deadline || Time.now + @read_timeout,
          allow_insecure_http:
        ) { |chunk| response_body << chunk }
        response_body
      end

      # Executes a bounded request and yields response chunks as they arrive.
      def each_chunk(uri:, method: :get, headers: {}, body: nil, deadline: nil,
        cancellation_token: nil, allow_insecure_http: false, label: "HTTP request")
        unless block_given?
          return enum_for(
            __method__, uri:, method:, headers:, body:, deadline:, cancellation_token:, allow_insecure_http:, label:
          )
        end

        uri = URI(uri.to_s)
        validate_uri!(uri, allow_insecure_http:)
        check_control!(cancellation_token, deadline)
        request_class = {get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put}.fetch(method.to_sym) do
          raise ArgumentError, "unsupported HTTP method: #{method}"
        end
        request = request_class.new(uri)
        headers.each { |name, value| request[name] = value unless value.to_s.empty? }
        request.body = body if body
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = remaining_timeout(deadline, @open_timeout)
        http.read_timeout = remaining_timeout(deadline, @read_timeout)
        http.write_timeout = remaining_timeout(deadline, @read_timeout)
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            response_body = read_limited(response, @max_error_body_bytes)
            raise Providers::HTTPError.new(
              "#{label} failed with HTTP #{response.code}",
              status: response.code.to_i,
              body: response_body
            )
          end

          bytes_read = 0
          response.read_body do |chunk|
            check_control!(cancellation_token, deadline)
            bytes_read += chunk.bytesize
            raise ProtocolError, "#{label} response exceeded #{@max_response_bytes} bytes" if bytes_read > @max_response_bytes

            yield chunk
          end
        end
      rescue *TRANSIENT_NETWORK_ERRORS => error
        raise Providers::HTTPError, "#{label} failed (#{error.class})"
      end

      private

      def check_control!(cancellation_token, deadline)
        cancellation_token&.raise_if_cancelled!
        raise DeadlineExceededError, "The request deadline was reached" if deadline && Time.now >= deadline
      end

      def validate_uri!(uri, allow_insecure_http:)
        unless %w[http https].include?(uri.scheme) && uri.host
          raise ConfigurationError, "HTTP endpoint must be an HTTP(S) URL"
        end
        if uri.scheme == "http" && !allow_insecure_http
          raise ConfigurationError, "HTTP endpoint must use HTTPS unless allow_insecure_http is enabled"
        end
      end

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
          break if body.bytesize >= limit
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
