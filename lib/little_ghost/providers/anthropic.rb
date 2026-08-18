# frozen_string_literal: true

require "base64"
require "json"
require_relative "../support/http_client"
require_relative "../support/sse_parser"
require_relative "anthropic/catalog_source"

module LittleGhost
  module Providers
    # Connects a Model to Anthropic's Messages API.
    #
    # Requests send messages, Tool definitions, attachments, and model settings
    # to the configured Anthropic endpoint. The adapter reads its credential
    # from trusted configuration, honors cancellation and deadlines, and emits
    # LittleGhost StreamEvents. HTTP and response-shape failures become
    # ProviderError subclasses. It uses the built-in HTTP client and does not
    # require Anthropic's SDK.
    class Anthropic < Base
      # Request policy supported by the Anthropic HTTP client.
      def self.request_options = %i[max_response_bytes open_timeout read_timeout].freeze

      DEFAULT_BASE_URL = "https://api.anthropic.com/v1/" # :nodoc:

      # Provider-owned model identifier.
      attr_reader :model

      # Creates an Anthropic Messages client for +model+.
      def initialize(api_key:, model:, base_url: DEFAULT_BASE_URL, api_version: "2023-06-01",
        open_timeout: 10, read_timeout: 120, max_response_bytes: Support::HTTPClient::DEFAULT_MAX_RESPONSE_BYTES,
        transport: nil, **)
        raise CredentialError, "Anthropic api_key is required" if api_key.to_s.empty?

        @api_key = api_key
        @api_version = api_version
        @model = model
        @transport = transport || Support::HTTPClient.new(base_url:, open_timeout:, read_timeout:, max_response_bytes:)
      end

      # Streams normalized events for +request+.
      def stream(request)
        return enum_for(__method__, request) unless block_given?

        parser = Support::SSEParser.new
        normalizer = Normalizer.new(model:)
        @transport.stream(
          path: "messages",
          headers: {
            "x-api-key" => @api_key,
            "anthropic-version" => @api_version,
            "content-type" => "application/json",
            "accept" => "text/event-stream"
          },
          body: JSON.generate(request_body(request)),
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        ) do |chunk|
          parser.<<(chunk).each { |data| normalizer.consume(JSON.parse(data)).each { |event| yield event } }
        end
        parser.finish.each { |data| normalizer.consume(JSON.parse(data)).each { |event| yield event } }
        normalizer.finish.each { |event| yield event }
      rescue JSON::ParserError => error
        raise ProtocolError, "Anthropic returned invalid JSON: #{error.message}"
      end

      # Reports tool and structured-output support from model metadata.
      def capabilities(metadata: {})
        parameters = metadata[:supported_parameters]
        ModelCapabilities.new(
          native_structured_output: parameters&.include?("structured_outputs"),
          tools: true,
          tool_choice: true,
          supported_parameters: parameters
        )
      end

      private

      def request_body(request)
        system, messages = request.messages.partition { |message| message.role == :system }
        body = {
          model:,
          stream: true,
          max_tokens: request.settings[:max_tokens] || 4096,
          messages: messages.map { |message| anthropic_message(message) }
        }
        body[:system] = system.flat_map { |message| message.content.map { |block| anthropic_content(block) } } unless system.empty?
        body[:tools] = request.tools.map { |tool| anthropic_tool(tool) } unless request.tools.empty?
        body[:tool_choice] = (request.tool_choice == :required) ? {type: "any"} : {type: "tool", name: request.tool_choice[:name].to_s} if request.tool_choice
        request.settings.each { |key, value| body[key] = value unless %i[reasoning_effort max_tokens].include?(key.to_sym) }
        body
      end

      def anthropic_message(message)
        {role: (message.role == :assistant) ? "assistant" : "user", content: message.content.map { |block| anthropic_content(block) }}
      end

      def anthropic_content(block)
        case block
        when Content::Text then {type: "text", text: block.text}
        when Content::Image then {type: "image", source: {type: "base64", media_type: block.media_type, data: Base64.strict_encode64(block.data)}}
        when Content::Document then {type: "document", source: {type: "base64", media_type: block.media_type, data: Base64.strict_encode64(block.data)}}
        when Content::ToolUse then {type: "tool_use", id: block.id, name: block.name, input: block.input}
        when Content::ToolResult
          {type: "tool_result", tool_use_id: block.tool_use_id, content: Array(block.content).join("\n"), is_error: block.status == :error}
        when Content::Reasoning then {type: "thinking", thinking: block.text, signature: block.signature}.compact
        else raise ConfigurationError, "Unsupported Anthropic content block: #{block.class}"
        end
      end

      def anthropic_tool(tool)
        value = tool.is_a?(Hash) ? tool.transform_keys(&:to_sym) : {name: tool.name, description: tool.description, input_schema: tool.input_schema}
        {name: value.fetch(:name), description: value[:description], input_schema: value[:input_schema] || {}}
      end

      class Normalizer # :nodoc:
        def initialize(model:)
          @model = model
          @text = +""
          @reasoning = +""
          @tools = {}
          @usage = Usage.new
          @terminal = false
        end

        def consume(event)
          case event["type"]
          when "message_start"
            message = event.fetch("message")
            @id = message["id"]
            @usage = usage(message["usage"])
            [StreamEvent.build(:message_start, id: @id, model: message["model"] || @model)]
          when "content_block_start"
            start_block(event)
          when "content_block_delta"
            delta_block(event)
          when "content_block_stop"
            stop_block(event)
          when "message_delta"
            @stop_reason = stop_reason(event.dig("delta", "stop_reason"))
            @usage = usage(event["usage"], previous: @usage)
            [StreamEvent.build(:usage, usage: @usage)]
          when "message_stop"
            @terminal = true
            []
          when "error"
            raise ProviderError, "Anthropic request failed: #{event.dig("error", "message") || "unknown error"}"
          else
            []
          end
        end

        def finish
          raise ProtocolError, "Anthropic stream ended before message_stop" unless @terminal

          blocks = []
          blocks << Content::Reasoning.new(text: @reasoning) unless @reasoning.empty?
          blocks << Content::Text.new(text: @text) unless @text.empty?
          @tools.sort.each { |_index, tool| blocks << Content::ToolUse.new(id: tool[:id], name: tool[:name], input: parse_input(tool[:input])) }
          response = ModelResponse.new(
            message: Message.new(role: :assistant, content: blocks),
            stop_reason: @stop_reason || (@tools.empty? ? :end_turn : :tool_use),
            usage: @usage,
            metadata: {id: @id, model: @model}
          )
          [StreamEvent.build(:message_stop, response:)]
        end

        private

        def start_block(event)
          block = event.fetch("content_block")
          return [] unless block["type"] == "tool_use"

          index = event.fetch("index")
          @tools[index] = {id: block["id"], name: block["name"], input: +""}
          [StreamEvent.build(:tool_call_start, index:, id: block["id"], name: block["name"])]
        end

        def delta_block(event)
          delta = event.fetch("delta")
          case delta["type"]
          when "text_delta"
            @text << delta.fetch("text")
            [StreamEvent.build(:text_delta, text: delta.fetch("text"))]
          when "thinking_delta"
            @reasoning << delta.fetch("thinking")
            [StreamEvent.build(:reasoning_delta, text: delta.fetch("thinking"))]
          when "input_json_delta"
            index = event.fetch("index")
            arguments = delta.fetch("partial_json")
            @tools.fetch(index)[:input] << arguments
            [StreamEvent.build(:tool_call_delta, index:, arguments:)]
          else []
          end
        end

        def stop_block(event)
          index = event.fetch("index")
          tool = @tools[index]
          return [] unless tool

          use = Content::ToolUse.new(id: tool[:id], name: tool[:name], input: parse_input(tool[:input]))
          [StreamEvent.build(:tool_call_stop, index:, tool_use: use)]
        end

        def parse_input(value) = value.empty? ? {} : JSON.parse(value)

        def usage(value, previous: Usage.new)
          value ||= {}
          cache_read = value["cache_read_input_tokens"] || previous.cache_read_tokens
          cache_write = value["cache_creation_input_tokens"] || previous.cache_write_tokens
          input = value["input_tokens"] || previous.input_tokens
          Usage.new(input_tokens: input, output_tokens: value["output_tokens"] || previous.output_tokens,
            cache_read_tokens: cache_read, cache_write_tokens: cache_write)
        end

        def stop_reason(value)
          case value
          when "tool_use" then :tool_use
          when "max_tokens" then :max_tokens
          when "refusal" then :content_filter
          else :end_turn
          end
        end
      end
    end
  end
end
