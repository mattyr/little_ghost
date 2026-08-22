# frozen_string_literal: true

require "json"
require "uri"

module LittleGhost
  module Providers
    class Bedrock < Base
      # Stdlib Bedrock Runtime client with the small ConverseStream surface used by
      # the adapter.
      class HTTPClient # :nodoc:
        Response = Data.define(:stream)
        InvokeResponse = Data.define(:body)
        DEFAULT_MAX_RESPONSE_BYTES = 256 * 1024 * 1024

        def initialize(region:, credentials: nil, credential_resolver: nil, endpoint: nil,
          open_timeout: 10, read_timeout: 120, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
          max_frame_bytes: EventStreamDecoder::DEFAULT_MAX_FRAME_BYTES, clock: -> { Time.now.utc })
          @region = region.to_s
          raise ConfigurationError, "Bedrock region is required" if @region.empty?

          @credential_resolver = credential_resolver || -> { credentials || CredentialResolver.new.call }
          @endpoint = URI(endpoint || "https://bedrock-runtime.#{@region}.amazonaws.com")
          raise ConfigurationError, "Bedrock endpoint must use HTTPS" unless @endpoint.scheme == "https"

          @max_frame_bytes = Integer(max_frame_bytes)
          @clock = clock
          @http_client = Support::HTTPClient.new(open_timeout:, read_timeout:, max_response_bytes:)
        end

        def converse_stream(**parameters)
          model_id = parameters.delete(:model_id)
          body = JSON.generate(camelize(parameters))
          uri = URI.join(@endpoint.to_s, "/model/#{escape_path(model_id)}/converse-stream")
          credentials = @credential_resolver.call
          signer = AwsSigV4.new(service: "bedrock", region: @region, credentials:, clock: @clock)
          headers = signer.headers(method: :post, uri:, headers: {"content-type" => "application/json"}, body:)
          stream = Enumerator.new do |events|
            decoder = EventStreamDecoder.new(max_frame_bytes: @max_frame_bytes)
            @http_client.each_chunk(uri:, method: :post, headers:, body:, label: "Bedrock request") do |chunk|
              decoder.<<(chunk).each { |event_headers, payload| events << event(event_headers, payload) }
            end
            decoder.finish
          end
          Response.new(stream:)
        end

        def invoke_model(model_id:, body:, max_response_bytes:, cancellation_token: nil, deadline: nil)
          payload = JSON.generate(camelize(body))
          uri = URI.join(@endpoint.to_s, "/model/#{escape_path(model_id)}/invoke")
          credentials = @credential_resolver.call
          signer = AwsSigV4.new(service: "bedrock", region: @region, credentials:, clock: @clock)
          headers = signer.headers(method: :post, uri:, headers: {"content-type" => "application/json", "accept" => "application/json"}, body: payload)
          response = @http_client.request(
            uri:, method: :post, headers:, body: payload,
            cancellation_token:, deadline:, label: "Bedrock request", max_response_bytes:
          )
          InvokeResponse.new(body: response)
        end

        private

        def event(headers, payload)
          value = payload.empty? ? {} : JSON.parse(payload)
          type = headers[":event-type"] || headers[":exception-type"]
          {underscore(type).to_sym => normalize_event_payload(value)}
        rescue JSON::ParserError => error
          raise ProtocolError, "Bedrock returned invalid event JSON: #{error.message}"
        end

        def camelize(value, json_schema: false, input_schema: false)
          case value
          when Hash
            value.to_h do |key, child|
              key = key.to_s
              [json_schema ? key : camelize_key(key), camelize(child, json_schema: json_schema || (input_schema && key == "json"), input_schema: key == "input_schema")]
            end
          when Array then value.map { |child| camelize(child, json_schema:, input_schema: false) }
          else value
          end
        end

        def camelize_key(key) = key.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }

        def normalize_event_payload(value)
          case value
          when Hash then value.to_h { |key, child| [underscore(key).to_sym, normalize_event_payload(child)] }
          when Array then value.map { |child| normalize_event_payload(child) }
          else value
          end
        end

        def underscore(value) = value.to_s.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase

        def escape_path(value) = URI.encode_www_form_component(value.to_s).gsub("+", "%20")
      end
    end
  end
end
