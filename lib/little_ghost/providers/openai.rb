# frozen_string_literal: true

require_relative "openai_compatible"

module LittleGhost
  module Providers
    # OpenAI connects LittleGhost features to OpenAI models for generation and
    # embeddings. Generation uses the Responses API by default and supports
    # streaming, Tools, and structured results.
    #
    #   provider = LittleGhost::Providers::OpenAI.new(
    #     api_key: ENV.fetch("OPENAI_API_KEY"),
    #     model: ENV.fetch("OPENAI_MODEL")
    #   )
    #
    # Supply <tt>api: :chat_completions</tt> only when a model or integration requires
    # the Chat Completions wire API.
    class OpenAI < OpenAICompatible
      # The OpenAI API endpoint used when +base_url+ is omitted.
      DEFAULT_BASE_URL = "https://api.openai.com/v1/"
      DEFAULT_MAX_EMBEDDING_RESPONSE_BYTES = 8 * 1024 * 1024 # :nodoc:

      # Uses the official OpenAI API base URL by default.
      #
      # +max_embedding_response_bytes+ bounds the response retained for one
      # embedding batch. Remaining +arguments+ configure the shared generation
      # transport and retry behavior.
      def initialize(base_url: DEFAULT_BASE_URL, max_embedding_response_bytes: DEFAULT_MAX_EMBEDDING_RESPONSE_BYTES, **arguments)
        @max_embedding_response_bytes = Integer(max_embedding_response_bytes)
        raise ArgumentError, "max_embedding_response_bytes must be positive" unless @max_embedding_response_bytes.positive?

        super(base_url:, **arguments)
      end

      # Embeds one or more strings with the configured OpenAI model.
      #
      # The optional +:dimensions+ request setting selects a supported output
      # size for models that accept it. The response preserves input order and
      # raises ProtocolError when OpenAI returns an incomplete or invalid batch.
      def embed(request)
        attempts = 0
        begin
          request.cancellation_token.raise_if_cancelled!
          payload = {
            model:,
            input: request.inputs,
            encoding_format: "float"
          }
          dimensions = request.settings[:dimensions]
          payload[:dimensions] = Integer(dimensions) if dimensions
          body = +""
          @transport.stream(
            path: "embeddings",
            headers: {"Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json"}.merge(@headers),
            body: JSON.generate(payload),
            cancellation_token: request.cancellation_token,
            deadline: request.deadline
          ) do |chunk|
            if body.bytesize + chunk.bytesize > @max_embedding_response_bytes
              raise ProtocolError, "OpenAI embedding response exceeded #{@max_embedding_response_bytes} bytes"
            end
            body << chunk
          end
          normalize_embedding_response(body, request.inputs.length, dimensions && Integer(dimensions))
        rescue HTTPError => error
          raise unless error.retryable? && attempts < @max_retries

          attempts += 1
          delay = capped_retry_delay(request, retry_delay(attempts))
          @on_retry.call(attempts, error, delay)
          wait_before_retry(request, delay)
          retry
        end
      end

      private

      def normalize_embedding_response(body, input_count, expected_dimensions)
        payload = JSON.parse(body)
        data = payload.fetch("data")
        raise ProtocolError, "OpenAI returned an invalid embedding count" unless data.is_a?(Array) && data.length == input_count

        ordered = data.sort_by { |item| Integer(item.fetch("index")) }
        expected = (0...input_count).to_a
        raise ProtocolError, "OpenAI returned invalid embedding indices" unless ordered.map { |item| Integer(item.fetch("index")) } == expected

        vectors = ordered.map { |item| item.fetch("embedding") }
        if expected_dimensions && vectors.any? { |vector| !vector.is_a?(Array) || vector.length != expected_dimensions }
          raise ProtocolError, "OpenAI returned embeddings with unexpected dimensions"
        end

        usage = payload.fetch("usage", {})
        Embeddings::Response.new(
          vectors:,
          usage: Usage.new(input_tokens: usage["prompt_tokens"] || usage["input_tokens"]),
          metadata: {model: payload["model"] || model}
        )
      rescue JSON::ParserError, KeyError, ArgumentError, TypeError
        raise ProtocolError, "OpenAI returned an invalid embedding response"
      end
    end
  end
end
