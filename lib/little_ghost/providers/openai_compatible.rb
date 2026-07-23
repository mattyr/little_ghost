# frozen_string_literal: true

require "json"
require_relative "sse_parser"
require_relative "http_transport"

module LittleGhost
  module Providers
    class OpenAICompatible
      DEFAULT_BASE_URL = "https://api.openai.com/v1/"
      INITIAL_RETRY_DELAY = 1
      MAX_RETRY_DELAY = 16
      TRANSIENT_STREAM_ERROR_TYPES = %w[
        provider_overloaded provider_unavailable rate_limit_exceeded server timeout
      ].freeze
      CONTEXT_OVERFLOW_MARKERS = [
        "context_length_exceeded", "context window", "maximum context length",
        "max context length", "input is too long", "too many input tokens"
      ].freeze

      class StreamError < ProviderError
        attr_reader :error_type, :code

        def initialize(message, error_type: nil, code: nil)
          @error_type = error_type.to_s.strip.downcase
          @code = code
          super(message)
        end

        def retryable?
          return true if TRANSIENT_STREAM_ERROR_TYPES.include?(error_type)
          return true if code.to_s.strip.downcase == "server_error"

          status = Integer(code, exception: false)
          status == 408 || status == 429 || (status && status >= 500)
        end

        def self.from(error, prefix:)
          value = error.is_a?(Hash) ? error : {}
          metadata = value["metadata"].is_a?(Hash) ? value["metadata"] : {}
          error_type = metadata["error_type"] || value["type"]
          code = value["code"]
          message = value["message"].to_s
          message = "unknown error" if message.empty?
          new("#{prefix}: #{message}", error_type:, code:)
        end
      end

      attr_reader :model, :api

      def initialize(
        api_key:,
        model:,
        base_url: DEFAULT_BASE_URL,
        api: :responses,
        headers: {},
        open_timeout: 10,
        read_timeout: 120,
        allow_insecure_http: false,
        max_response_bytes: HTTPTransport::DEFAULT_MAX_RESPONSE_BYTES,
        max_retries: 2,
        transport: nil,
        sleeper: nil,
        on_retry: ->(*) {}
      )
        @api_key = api_key
        @model = model
        @api = api.to_sym
        raise ConfigurationError, "api must be :responses or :chat_completions" unless %i[responses chat_completions].include?(@api)

        @headers = headers.transform_keys(&:to_s).freeze
        @max_retries = Integer(max_retries)
        @transport = transport || HTTPTransport.new(
          base_url:,
          open_timeout:,
          read_timeout:,
          allow_insecure_http:,
          max_response_bytes:
        )
        @sleeper = sleeper
        @on_retry = on_retry
      end

      def stream(request)
        return enum_for(__method__, request) unless block_given?

        attempts = 0

        begin
          request.cancellation_token.raise_if_cancelled!
          stream_once(request) { |event| yield event }
        rescue HTTPError, StreamError => error
          if context_window_overflow?(error)
            raise ContextWindowOverflowError, "The model context window was exceeded"
          end
          raise if !error.retryable? || attempts >= @max_retries

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

      def context_window_overflow?(error)
        values = [error.message]
        values << error.body if error.respond_to?(:body)
        values << error.error_type << error.code if error.is_a?(StreamError)
        text = values.compact.join(" ").downcase
        CONTEXT_OVERFLOW_MARKERS.any? { |marker| text.include?(marker) }
      end

      def stream_once(request)
        parser = SSEParser.new
        normalizer = normalizer_for(request)

        @transport.stream(
          path: endpoint,
          headers: request_headers(request),
          body: JSON.generate(request_body(request)),
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        ) do |chunk|
          parser.<<(chunk).each { |data| emit_data(data, normalizer) { |event| yield event } }
        end
        parser.finish.each { |data| emit_data(data, normalizer) { |event| yield event } }
        normalizer.finish.each { |event| yield event }
      rescue JSON::ParserError => error
        raise ProtocolError, "Provider returned invalid JSON: #{error.message}"
      end

      def emit_data(data, normalizer)
        if data == "[DONE]"
          normalizer.stream_done
          return
        end

        normalizer.consume(JSON.parse(data)).each { |event| yield event }
      end

      def endpoint
        (api == :responses) ? "responses" : "chat/completions"
      end

      def request_headers(request)
        {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type" => "application/json",
          "Accept" => "text/event-stream"
        }.merge(@headers).merge(dynamic_headers(request))
      end

      def dynamic_headers(_request)
        {}
      end

      def request_body(request)
        common = compact_hash(model:, stream: true).merge(provider_settings(request.settings))
        if api == :responses && common.key?(:max_tokens) && !common.key?(:max_output_tokens)
          common[:max_output_tokens] = common.delete(:max_tokens)
        end
        body = if api == :responses
          common.merge(input: responses_input(request.messages), tools: responses_tools(request.tools))
        else
          common.merge(messages: chat_messages(request.messages), tools: chat_tools(request.tools), stream_options: {include_usage: true})
        end
        body.delete(:tools) if request.tools.empty?
        body
      end

      def provider_settings(settings)
        allowed = %i[temperature top_p max_tokens max_output_tokens stop seed service_tier user metadata]
        settings.each_with_object({}) do |(key, value), result|
          symbol = key.to_sym
          result[symbol] = value if allowed.include?(symbol)
        end
      end

      def responses_input(messages)
        messages.flat_map do |message|
          tool_items = message.content.filter_map { |block| responses_tool_item(block) }
          regular = message.content.reject do |block|
            block.is_a?(Content::ToolUse) || block.is_a?(Content::ToolResult) || block.is_a?(Content::Reasoning)
          end
          item = {role: message.role.to_s, content: regular.map { |block| responses_content(block, message.role) }} unless regular.empty?
          [item, *tool_items].compact
        end
      end

      def responses_tool_item(block)
        case block
        when Content::ToolUse
          {type: "function_call", call_id: block.id, name: block.name, arguments: JSON.generate(block.input)}
        when Content::ToolResult
          {type: "function_call_output", call_id: block.tool_use_id, output: tool_result_text(block)}
        end
      end

      def responses_content(block, role)
        case block
        when Content::Text
          {type: "input_text", text: block.text}
        when Content::Image
          {type: "input_image", image_url: data_url(block.data, block.media_type)}
        when Content::Document
          {type: "input_file", filename: block.name, file_data: data_url(block.data, block.media_type)}
        else
          raise ConfigurationError, "Unsupported Responses content block: #{block.class}"
        end
      end

      def chat_messages(messages)
        messages.flat_map do |message|
          tool_results = message.content.grep(Content::ToolResult).map do |result|
            {role: "tool", tool_call_id: result.tool_use_id, content: tool_result_text(result)}
          end
          regular = message.content.reject { |block| block.is_a?(Content::ToolResult) || block.is_a?(Content::Reasoning) }
          reasoning_fields = chat_reasoning_fields(message)
          entry = unless regular.empty? && reasoning_fields.empty?
            compact_hash(
              role: message.role.to_s,
              content: chat_content(regular),
              tool_calls: chat_tool_calls(regular)
            ).merge(reasoning_fields)
          end
          [entry, *tool_results].compact
        end
      end

      def chat_content(blocks)
        content = blocks.filter_map do |block|
          case block
          when Content::Text then {type: "text", text: block.text}
          when Content::Image then {type: "image_url", image_url: {url: data_url(block.data, block.media_type)}}
          when Content::Document then {type: "file", file: {filename: block.name, file_data: data_url(block.data, block.media_type)}}
          end
        end
        content unless content.empty?
      end

      def chat_tool_calls(blocks)
        calls = blocks.grep(Content::ToolUse).map do |tool_use|
          {id: tool_use.id, type: "function", function: {name: tool_use.name, arguments: JSON.generate(tool_use.input)}}
        end
        calls unless calls.empty?
      end

      def chat_reasoning_fields(_message) = {}

      def responses_tools(tools)
        tools.map do |tool|
          definition = tool_definition(tool)
          {type: "function", name: definition[:name], description: definition[:description], parameters: definition[:input_schema]}
        end
      end

      def chat_tools(tools)
        responses_tools(tools).map { |definition| {type: "function", function: definition.except(:type)} }
      end

      def tool_definition(tool)
        if tool.is_a?(Hash)
          definition = tool.transform_keys(&:to_sym)
          return {
            name: definition.fetch(:name),
            description: definition[:description],
            input_schema: definition[:input_schema] || {}
          }
        end

        {
          name: tool.public_send(:name),
          description: tool.public_send(:description),
          input_schema: tool.public_send(:input_schema)
        }
      end

      def tool_result_text(result)
        Array(result.content).map { |block| block.is_a?(Content::Text) ? block.text : block.to_s }.join
      end

      def data_url(data, media_type)
        return data if data.to_s.start_with?("data:", "http://", "https://")

        "data:#{media_type};base64,#{[data].pack("m0")}"
      end

      def normalizer_for(request)
        (api == :responses) ? ResponsesNormalizer.new(model:) : ChatNormalizer.new(model:)
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

      def compact_hash(hash)
        hash.reject { |_key, value| value.nil? }
      end

      class Normalizer
        def initialize(model:)
          @model = model
          @message_id = nil
          @text = +""
          @reasoning = +""
          @tool_calls = {}
          @usage = Usage.new
          @stop_reason = nil
          @finished = false
        end

        def finish
          return [] if @finished
          raise ProtocolError, "Provider stream ended before its terminal event" unless @terminal

          [final_event]
        end

        def stream_done
          @terminal = true
        end

        private

        def start_event(id, model = nil)
          @message_id ||= id
          StreamEvent.build(:message_start, id: @message_id, model: model || @model)
        end

        def text_delta(text)
          @text << text
          StreamEvent.build(:text_delta, text:)
        end

        def reasoning_delta(text)
          @reasoning << text
          StreamEvent.build(:reasoning_delta, text:)
        end

        def tool_start(index, id, name)
          state = (@tool_calls[index] ||= {id: id, name: name, arguments: +"", started: false})
          state[:id] ||= id
          state[:name] ||= name
          return if state[:started]

          state[:started] = true
          StreamEvent.build(:tool_call_start, index:, id: state[:id], name: state[:name])
        end

        def tool_delta(index, arguments)
          state = (@tool_calls[index] ||= {id: nil, name: nil, arguments: +"", started: false})
          state[:arguments] << arguments
          StreamEvent.build(:tool_call_delta, index:, arguments:)
        end

        def tool_stop(index, complete_arguments: nil)
          state = @tool_calls.fetch(index)
          state[:arguments] = complete_arguments unless complete_arguments.nil? || complete_arguments.empty?
          input = state[:arguments].empty? ? {} : JSON.parse(state[:arguments])
          tool_use = Content::ToolUse.new(id: state[:id], name: state[:name], input:)
          StreamEvent.build(:tool_call_stop, index:, tool_use:)
        rescue JSON::ParserError, ArgumentError => error
          raise MalformedToolCallError, "Provider returned an invalid tool call: #{error.message}"
        end

        def usage_event(usage)
          @usage = usage
          StreamEvent.build(:usage, usage:)
        end

        def final_event
          @finished = true
          blocks = []
          reasoning = reasoning_content
          blocks << reasoning if reasoning
          blocks << Content::Text.new(text: @text) unless @text.empty?
          @tool_calls.sort.map do |_index, state|
            input = state[:arguments].empty? ? {} : JSON.parse(state[:arguments])
            blocks << Content::ToolUse.new(id: state[:id], name: state[:name], input:)
          end
          response = ModelResponse.new(
            message: Message.new(role: :assistant, content: blocks),
            stop_reason: final_stop_reason,
            usage: @usage,
            metadata: {id: @message_id, model: @model}
          )
          StreamEvent.build(:message_stop, response:)
        rescue JSON::ParserError, ArgumentError => error
          raise MalformedToolCallError, "Provider returned an invalid tool call: #{error.message}"
        end

        def normalize_usage(input:, output:, cache_read: 0, cache_write: 0, reasoning: 0)
          cache_read = Integer(cache_read || 0)
          cache_write = Integer(cache_write || 0)
          reasoning = Integer(reasoning || 0)
          uncached_input = [Integer(input || 0) - cache_read - cache_write, 0].max
          visible_output = [Integer(output || 0) - reasoning, 0].max
          Usage.new(
            input_tokens: uncached_input,
            output_tokens: visible_output,
            cache_read_tokens: cache_read,
            cache_write_tokens: cache_write,
            reasoning_tokens: reasoning
          )
        end

        def reasoning_content
          Content::Reasoning.new(text: @reasoning) unless @reasoning.empty?
        end

        def final_stop_reason
          return :tool_use if !@tool_calls.empty? && (@stop_reason.nil? || @stop_reason == :end_turn)

          @stop_reason || :end_turn
        end

        def stop_reason(value)
          case value
          when "tool_calls", "function_call" then :tool_use
          when "length", "max_tokens", "incomplete" then :max_tokens
          when "content_filter" then :content_filter
          when nil then nil
          else :end_turn
          end
        end
      end

      class ResponsesNormalizer < Normalizer
        def stream_done
          nil
        end

        def consume(event)
          type = event["type"]
          case type
          when "response.created"
            response = event.fetch("response")
            [start_event(response["id"], response["model"])]
          when "response.output_text.delta"
            [text_delta(event.fetch("delta"))]
          when "response.reasoning_text.delta", "response.reasoning_summary_text.delta"
            [reasoning_delta(event.fetch("delta"))]
          when "response.output_item.added"
            item = event.fetch("item")
            return [] unless item["type"] == "function_call"

            [tool_start(event.fetch("output_index"), item["call_id"] || item["id"], item["name"])]
          when "response.function_call_arguments.delta"
            [tool_delta(event.fetch("output_index"), event.fetch("delta"))]
          when "response.output_item.done"
            item = event.fetch("item")
            return [] unless item["type"] == "function_call"

            [tool_stop(event.fetch("output_index"), complete_arguments: item["arguments"])]
          when "response.completed", "response.incomplete"
            response = event.fetch("response")
            @message_id ||= response["id"]
            @model = response["model"] || @model
            @stop_reason = (type == "response.incomplete") ? :max_tokens : stop_reason(response["status"])
            events = []
            events << usage_event(responses_usage(response["usage"])) if response["usage"]
            events << final_event
          when "response.failed"
            error = event.dig("response", "error") || {}
            raise StreamError.from(error, prefix: "Provider stream failed")
          when "error"
            error = event["error"] || event
            raise StreamError.from(error, prefix: "Provider stream error")
          else
            []
          end
        end

        private

        def responses_usage(value)
          input_details = value["input_tokens_details"] || {}
          output_details = value["output_tokens_details"] || {}
          normalize_usage(
            input: value["input_tokens"],
            output: value["output_tokens"],
            cache_read: input_details["cached_tokens"],
            cache_write: input_details["cache_write_tokens"] || output_details["cache_write_tokens"],
            reasoning: output_details["reasoning_tokens"] || value["reasoning_tokens"]
          )
        end
      end

      class ChatNormalizer < Normalizer
        def initialize(...)
          super
          @reasoning_details = []
        end

        def consume(event)
          if event["error"]
            raise StreamError.from(event["error"], prefix: "Provider stream error")
          end

          events = []
          events << start_event(event["id"], event["model"]) unless @message_id
          choice = event.fetch("choices", []).first
          if choice
            delta = choice["delta"] || {}
            events << text_delta(delta["content"]) if delta["content"]
            reasoning = delta["reasoning_content"] || delta["reasoning"]
            events << reasoning_delta(reasoning) if reasoning
            capture_reasoning_details(delta["reasoning_details"]) if delta.key?("reasoning_details")
            delta.fetch("tool_calls", []).each do |call|
              index = call.fetch("index")
              function = call["function"] || {}
              if call["id"] || function["name"]
                started = tool_start(index, call["id"], function["name"])
                events << started if started
              end
              events << tool_delta(index, function["arguments"]) if function["arguments"]
            end
            if choice["finish_reason"]
              @stop_reason = stop_reason(choice["finish_reason"])
              @terminal = true
            end
          end
          events << usage_event(chat_usage(event["usage"])) if event["usage"]
          events
        end

        def finish
          events = @tool_calls.keys.sort.map { |index| tool_stop(index) }
          events.concat(super)
        end

        private

        def capture_reasoning_details(details)
          unless details.is_a?(Array) && details.all? { |detail| detail.is_a?(Hash) }
            raise ProtocolError, "Provider returned invalid reasoning details"
          end

          @reasoning_details.concat(details.map(&:dup))
        end

        def reasoning_content
          details = merged_reasoning_details
          return if @reasoning.empty? && details.empty?

          Content::Reasoning.new(
            text: @reasoning,
            details: details.empty? ? nil : details
          )
        end

        def merged_reasoning_details
          @reasoning_details.each_with_object([]) do |detail, merged|
            previous = merged.last
            if mergeable_reasoning_details?(previous, detail)
              combined = previous.merge(detail) { |_key, old_value, new_value| new_value.nil? ? old_value : new_value }
              if reasoning_detail_text?(previous) || reasoning_detail_text?(detail)
                text_key = "text"
                text_key = :text if detail.key?(:text)
                combined.delete("text")
                combined.delete(:text)
                combined[text_key] = reasoning_detail_text(previous) + reasoning_detail_text(detail)
              end
              merged[-1] = combined
            else
              merged << detail.dup
            end
          end
        end

        def mergeable_reasoning_details?(left, right)
          return false unless left

          left_type = left["type"] || left[:type]
          right_type = right["type"] || right[:type]
          left_index = left.key?("index") ? left["index"] : left[:index]
          right_index = right.key?("index") ? right["index"] : right[:index]
          !left_type.nil? && !left_index.nil? && left_type == right_type && left_index == right_index
        end

        def reasoning_detail_text?(detail)
          detail.key?("text") || detail.key?(:text)
        end

        def reasoning_detail_text(detail)
          (detail["text"] || detail[:text]).to_s
        end

        def chat_usage(value)
          prompt_details = value["prompt_tokens_details"] || {}
          completion_details = value["completion_tokens_details"] || {}
          normalize_usage(
            input: value["prompt_tokens"],
            output: value["completion_tokens"],
            cache_read: prompt_details["cached_tokens"] || value["cache_read_input_tokens"],
            cache_write: prompt_details["cache_write_tokens"] || value["cache_creation_input_tokens"],
            reasoning: completion_details["reasoning_tokens"] || value["reasoning_tokens"]
          )
        end
      end
    end
  end
end
