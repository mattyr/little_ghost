# frozen_string_literal: true

require "json"

module LittleGhost
  module Providers
    class Bedrock
      INITIAL_RETRY_DELAY = 1
      MAX_RETRY_DELAY = 16
      TRANSIENT_STREAM_ERRORS = %w[
        internal_server_exception model_stream_error_exception service_unavailable_exception throttling_exception
      ].freeze
      CONTEXT_OVERFLOW_MARKERS = [
        "context window", "maximum context length", "max context length",
        "input is too long", "too many input tokens"
      ].freeze

      class StreamError < ProviderError
        attr_reader :event_type

        def initialize(message, event_type:)
          @event_type = event_type.to_s
          super(message)
        end

        def retryable? = TRANSIENT_STREAM_ERRORS.include?(event_type)
      end

      attr_reader :model

      def initialize(model:, region: nil, client: nil, max_retries: 2, sleeper: nil,
        on_retry: ->(*) {}, **client_options)
        @model = model
        @client = client || build_client(region:, **client_options)
        @max_retries = Integer(max_retries)
        @sleeper = sleeper
        @on_retry = on_retry
      end

      def stream(request)
        return enum_for(__method__, request) unless block_given?

        attempts = 0

        begin
          request.cancellation_token.raise_if_cancelled!
          normalizer = StreamNormalizer.new(model:)
          stream = Support::InterruptibleStream.new(
            cancellation_token: request.cancellation_token,
            deadline: request.deadline
          ) do |emit|
            response = @client.converse_stream(**request_parameters(request))
            response.stream.each { |event| emit.call(event) }
          end
          stream.each do |event|
            normalizer.consume(event_hash(event)).each do |normalized|
              yield normalized
            end
          end
          normalizer.finish.each do |event|
            yield event
          end
        rescue CancelledError, DeadlineExceededError, CleanupError
          raise
        rescue => error
          raise if error.is_a?(Error) && !error.is_a?(StreamError)

          if context_window_overflow?(error)
            raise ContextWindowOverflowError, "The model context window was exceeded"
          end
          raise provider_error(error) if !retryable?(error) || attempts >= @max_retries

          attempts += 1
          request.cancellation_token.raise_if_cancelled!
          delay = capped_retry_delay(request, retry_delay(attempts))
          @on_retry.call(attempts, error, delay)
          wait_before_retry(request, delay)
          yield StreamEvent.build(:model_retry, attempt: attempts, delay:, error_class: error.class.name)
          retry
        end
      end

      private

      def build_client(region:, **options)
        require "aws-sdk-bedrockruntime"
        Aws::BedrockRuntime::Client.new(**options, **({region:} if region))
      rescue LoadError
        raise ConfigurationError,
          "Bedrock requires the optional aws-sdk-bedrockruntime gem; add it to your application's Gemfile"
      end

      def request_parameters(request)
        reasoning_effort = request.settings[:reasoning_effort] || request.settings["reasoning_effort"]
        if reasoning_effort && reasoning_effort.to_s != "none"
          raise ConfigurationError, "Bedrock does not support reasoning_effort"
        end

        system, messages = request.messages.partition { |message| message.role == :system }
        parameters = {
          model_id: model,
          messages: messages.filter_map { |message| bedrock_message(message) }
        }
        parameters[:system] = system.flat_map { |message| message.content.grep(Content::Text).map { |block| {text: block.text} } }
        parameters[:tool_config] = {tools: request.tools.map { |tool| bedrock_tool(tool) }} unless request.tools.empty?

        inference = extract_settings(request.settings, %i[max_tokens temperature top_p stop_sequences])
        parameters[:inference_config] = inference unless inference.empty?
        additional = request.settings[:additional_model_request_fields] || request.settings["additional_model_request_fields"]
        parameters[:additional_model_request_fields] = additional if additional
        parameters
      end

      def bedrock_message(message)
        role = (message.role == :assistant) ? "assistant" : "user"
        content = message.content.filter_map { |block| bedrock_content(block) }
        {role:, content:} unless content.empty?
      end

      def bedrock_content(block)
        case block
        when Content::Text
          {text: block.text}
        when Content::Reasoning
          if block.redacted_content
            {reasoning_content: {redacted_content: block.redacted_content}}
          elsif !block.text.empty?
            reasoning_text = {text: block.text}
            reasoning_text[:signature] = block.signature unless block.signature.to_s.empty?
            {reasoning_content: {reasoning_text:}}
          end
        when Content::Image
          {image: {format: image_format(block.media_type), source: {bytes: block.data}}}
        when Content::Document
          {document: {format: document_format(block.media_type, block.name), name: block.name, source: {bytes: block.data}}}
        when Content::ToolUse
          {tool_use: {tool_use_id: block.id, name: block.name, input: block.input}}
        when Content::ToolResult
          {
            tool_result: {
              tool_use_id: block.tool_use_id,
              content: Array(block.content).map { |content| {text: content.respond_to?(:text) ? content.text : content.to_s} },
              status: block.status.to_s
            }
          }
        else
          raise ConfigurationError, "Unsupported Bedrock content block: #{block.class}"
        end
      end

      def bedrock_tool(tool)
        definition = if tool.is_a?(Hash)
          tool.transform_keys(&:to_sym)
        else
          {name: tool.public_send(:name), description: tool.public_send(:description), input_schema: tool.public_send(:input_schema)}
        end
        {
          tool_spec: {
            name: definition.fetch(:name),
            description: definition[:description],
            input_schema: {json: definition[:input_schema] || {}}
          }
        }
      end

      def extract_settings(settings, keys)
        keys.each_with_object({}) do |key, result|
          value = settings[key] || settings[key.to_s]
          result[key] = value unless value.nil?
        end
      end

      def image_format(media_type)
        format = {"image/jpeg" => "jpeg", "image/png" => "png", "image/gif" => "gif", "image/webp" => "webp"}[media_type.to_s.downcase]
        return format if format

        raise ConfigurationError, "Unsupported Bedrock image media type: #{media_type}"
      end

      def document_format(media_type, name)
        format = {
          "application/pdf" => "pdf",
          "text/csv" => "csv",
          "application/msword" => "doc",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
          "application/vnd.ms-excel" => "xls",
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
          "text/html" => "html",
          "text/plain" => "txt",
          "text/markdown" => "md"
        }[media_type.to_s.downcase]
        format ||= File.extname(name.to_s).delete_prefix(".").downcase
        return format if %w[pdf csv doc docx xls xlsx html txt md].include?(format)

        raise ConfigurationError, "Unsupported Bedrock document media type: #{media_type}"
      end

      def event_hash(event)
        value = event.respond_to?(:to_h) ? event.to_h : event
        deep_stringify(value)
      end

      def deep_stringify(value)
        case value
        when Hash then value.to_h { |key, child| [key.to_s, deep_stringify(child)] }
        when Array then value.map { |child| deep_stringify(child) }
        else value
        end
      end

      def retryable?(error)
        return error.retryable? if error.is_a?(StreamError)

        name = error.class.name
        name.match?(/Timeout|ServiceUnavailable|InternalServer|Connection|Networking/)
      end

      def context_window_overflow?(error)
        message = error.message.to_s.downcase
        CONTEXT_OVERFLOW_MARKERS.any? { |marker| message.include?(marker) }
      end

      def retry_delay(attempt)
        [INITIAL_RETRY_DELAY * (2**(attempt - 1)), MAX_RETRY_DELAY].min
      end

      def capped_retry_delay(request, delay)
        return delay unless request.deadline

        remaining = request.deadline - Time.now
        raise DeadlineExceededError, "The run deadline was reached" unless remaining.positive?

        [delay, remaining].min
      end

      def wait_before_retry(request, delay)
        request.cancellation_token.raise_if_cancelled!
        delay = capped_retry_delay(request, delay)
        @sleeper ? @sleeper.call(delay) : request.cancellation_token.wait(delay)
        request.cancellation_token.raise_if_cancelled!
        raise DeadlineExceededError, "The run deadline was reached" if request.deadline && Time.now >= request.deadline
      end

      def provider_error(error)
        return error if error.is_a?(ProviderError)

        ProviderError.new("Bedrock request failed: #{error.message}")
      end

      class StreamNormalizer
        def initialize(model:)
          @model = model
          @message_id = nil
          @text = +""
          @reasoning_blocks = {}
          @tool_calls = {}
          @usage = Usage.new
          @stop_reason = nil
          @finished = false
        end

        def consume(event)
          if event["event_type"]
            type = event["event_type"].to_s
            payload = event.except("event_type")
          else
            type, payload = event.first
          end
          case type
          when "message_start"
            @message_id = payload["role"]
            [StreamEvent.build(:message_start, id: nil, model: @model)]
          when "content_block_start"
            content_start(payload)
          when "content_block_delta"
            content_delta(payload)
          when "content_block_stop"
            content_stop(payload)
          when "message_stop"
            @stop_reason = normalize_stop(payload["stop_reason"])
            @terminal = true
            []
          when "metadata"
            metadata(payload)
          when *TRANSIENT_STREAM_ERRORS, "validation_exception"
            message = payload.is_a?(Hash) ? payload["message"].to_s : ""
            message = "Bedrock returned #{type}" if message.empty?
            raise StreamError.new(message, event_type: type)
          else
            []
          end
        end

        def finish
          return [] if @finished
          raise ProtocolError, "Bedrock stream ended before message_stop" unless @terminal

          @finished = true
          blocks = []
          @reasoning_blocks.sort.each do |_index, reasoning|
            if !reasoning[:redacted_content].empty?
              blocks << Content::Reasoning.new(redacted_content: reasoning[:redacted_content])
            elsif !reasoning[:text].empty?
              signature = reasoning[:signature]
              blocks << Content::Reasoning.new(
                text: reasoning[:text],
                signature: signature.empty? ? nil : signature
              )
            end
          end
          blocks << Content::Text.new(text: @text) unless @text.empty?
          @tool_calls.sort.each do |_index, tool|
            input = tool[:arguments].empty? ? {} : JSON.parse(tool[:arguments])
            blocks << Content::ToolUse.new(id: tool[:id], name: tool[:name], input:)
          end
          response = ModelResponse.new(
            message: Message.new(role: :assistant, content: blocks),
            stop_reason: @stop_reason || (@tool_calls.empty? ? :end_turn : :tool_use),
            usage: @usage,
            metadata: {model: @model}
          )
          [StreamEvent.build(:message_stop, response:)]
        rescue JSON::ParserError, ArgumentError => error
          raise MalformedToolCallError, "Bedrock returned an invalid tool call: #{error.message}"
        end

        private

        def content_start(payload)
          index = payload.fetch("content_block_index")
          tool = payload.fetch("start", {})["tool_use"]
          return [] unless tool

          @tool_calls[index] = {id: tool["tool_use_id"], name: tool["name"], arguments: +""}
          [StreamEvent.build(:tool_call_start, index:, id: tool["tool_use_id"], name: tool["name"])]
        end

        def content_delta(payload)
          index = payload.fetch("content_block_index")
          delta = payload.fetch("delta")
          if delta["text"]
            @text << delta["text"]
            [StreamEvent.build(:text_delta, text: delta["text"])]
          elsif (reasoning_delta = delta["reasoning_content"])
            reasoning = (@reasoning_blocks[index] ||= {
              text: +"", signature: +"", redacted_content: String.new(encoding: Encoding::BINARY)
            })
            events = []
            if (text = reasoning_delta["text"])
              reasoning[:text] << text
              events << StreamEvent.build(:reasoning_delta, text:)
            end
            reasoning[:signature] << reasoning_delta["signature"] if reasoning_delta["signature"]
            reasoning[:redacted_content] << reasoning_delta["redacted_content"] if reasoning_delta["redacted_content"]
            events
          elsif delta["tool_use"]
            arguments = delta.dig("tool_use", "input") || ""
            @tool_calls.fetch(index)[:arguments] << arguments
            [StreamEvent.build(:tool_call_delta, index:, arguments:)]
          else
            []
          end
        end

        def content_stop(payload)
          index = payload.fetch("content_block_index")
          tool = @tool_calls[index]
          return [] unless tool

          input = tool[:arguments].empty? ? {} : JSON.parse(tool[:arguments])
          use = Content::ToolUse.new(id: tool[:id], name: tool[:name], input:)
          [StreamEvent.build(:tool_call_stop, index:, tool_use: use)]
        rescue JSON::ParserError, ArgumentError => error
          raise MalformedToolCallError, "Bedrock returned an invalid tool call: #{error.message}"
        end

        def metadata(payload)
          value = payload["usage"] || {}
          cache_read = Integer(value["cache_read_input_tokens"] || 0)
          cache_write = Integer(value["cache_write_input_tokens"] || 0)
          @usage = Usage.new(
            input_tokens: [Integer(value["input_tokens"] || 0) - cache_read - cache_write, 0].max,
            output_tokens: value["output_tokens"],
            cache_read_tokens: cache_read,
            cache_write_tokens: cache_write
          )
          [StreamEvent.build(:usage, usage: @usage)]
        end

        def normalize_stop(value)
          case value
          when "tool_use" then :tool_use
          when "max_tokens" then :max_tokens
          when "guardrail_intervened", "content_filtered" then :content_filter
          else :end_turn
          end
        end
      end
    end
  end
end
