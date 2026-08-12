# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module LittleGhost
  module Providers
    # Stdlib Bedrock Runtime client with the small ConverseStream surface used by
    # the adapter.
    class BedrockHTTPClient # :nodoc:
      Response = Data.define(:stream)
      DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024 * 1024

      def initialize(region:, credentials: nil, credential_resolver: nil, endpoint: nil,
        open_timeout: 10, read_timeout: 120, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
        max_frame_bytes: AwsEventStreamDecoder::DEFAULT_MAX_FRAME_BYTES, clock: -> { Time.now.utc })
        @region = region.to_s
        raise ConfigurationError, "Bedrock region is required" if @region.empty?

        @credential_resolver = credential_resolver || -> { credentials || AwsCredentialResolver.new.call }
        @endpoint = URI(endpoint || "https://bedrock-runtime.#{@region}.amazonaws.com")
        raise ConfigurationError, "Bedrock endpoint must use HTTPS" unless @endpoint.scheme == "https"

        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_response_bytes = Integer(max_response_bytes)
        @max_frame_bytes = Integer(max_frame_bytes)
        @clock = clock
      end

      def converse_stream(**parameters)
        model_id = parameters.delete(:model_id)
        body = JSON.generate(camelize(parameters))
        uri = URI.join(@endpoint.to_s, "/model/#{escape_path(model_id)}/converse-stream")
        credentials = @credential_resolver.call
        signer = AwsSigV4.new(service: "bedrock", region: @region, credentials:, clock: @clock)
        headers = signer.headers(method: :post, uri:, headers: {"content-type" => "application/json"}, body:)
        stream = Enumerator.new do |events|
          request = Net::HTTP::Post.new(uri)
          headers.each { |name, value| request[name] = value }
          request.body = body
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
          decoder = AwsEventStreamDecoder.new(max_frame_bytes: @max_frame_bytes)
          response_bytes = 0
          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              error_body = +""
              response.read_body do |chunk|
                remaining = 4096 - error_body.bytesize
                error_body << chunk.byteslice(0, remaining) if remaining.positive?
              end
              raise HTTPError.new("Bedrock request failed with HTTP #{response.code}", status: response.code.to_i, body: error_body)
            end
            response.read_body do |chunk|
              response_bytes += chunk.bytesize
              raise ProtocolError, "Bedrock response exceeds the configured limit" if response_bytes > @max_response_bytes

              decoder.<<(chunk).each { |event_headers, payload| events << event(event_headers, payload) }
            end
          end
          decoder.finish
        rescue *HTTPTransport::TRANSIENT_NETWORK_ERRORS => error
          raise HTTPError, "Bedrock request failed (#{error.class})"
        end
        Response.new(stream:)
      end

      private

      def event(headers, payload)
        value = payload.empty? ? {} : JSON.parse(payload)
        type = headers[":event-type"] || headers[":exception-type"]
        {type.to_s.gsub(/([a-z])([A-Z])/, "\\1_\\2").downcase.to_sym => symbolize(value)}
      rescue JSON::ParserError => error
        raise ProtocolError, "Bedrock returned invalid event JSON: #{error.message}"
      end

      def camelize(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }, camelize(child)] }
        when Array then value.map { |child| camelize(child) }
        else value
        end
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, child| [key.to_sym, symbolize(child)] }
        when Array then value.map { |child| symbolize(child) }
        else value
        end
      end

      def escape_path(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end
  end
end
