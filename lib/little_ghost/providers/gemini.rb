# frozen_string_literal: true

require "base64"
require "json"
require "uri"
require_relative "../support/http_client"
require_relative "../support/sse_parser"
require_relative "gemini/catalog_source"

module LittleGhost
  module Providers
    # Zero-dependency Gemini generateContent adapter.
    class Gemini < Base
      DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/" # :nodoc:

      # Provider-owned model identifier.
      attr_reader :model

      # Creates a Gemini generateContent client for +model+.
      def initialize(api_key:, model:, base_url: DEFAULT_BASE_URL, open_timeout: 10, read_timeout: 120,
        max_response_bytes: Support::HTTPClient::DEFAULT_MAX_RESPONSE_BYTES, transport: nil, **)
        raise CredentialError, "Gemini api_key is required" if api_key.to_s.empty?

        @api_key = api_key
        @model = model
        @transport = transport || Support::HTTPClient.new(base_url:, open_timeout:, read_timeout:, max_response_bytes:)
      end

      def stream(request)
        return enum_for(__method__, request) unless block_given?

        parser = Support::SSEParser.new
        normalizer = Normalizer.new(model:)
        @transport.stream(
          path: endpoint,
          headers: request_headers(request),
          body: JSON.generate(request_body(request)),
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        ) do |chunk|
          parser.<<(chunk).each { |data| normalizer.consume(JSON.parse(data)).each { |event| yield event } }
        end
        parser.finish.each { |data| normalizer.consume(JSON.parse(data)).each { |event| yield event } }
        normalizer.finish.each { |event| yield event }
      rescue JSON::ParserError => error
        raise ProtocolError, "Google returned invalid JSON: #{error.message}"
      end

      def capabilities(metadata: {})
        ModelCapabilities.new(native_structured_output: true, tools: true, tool_choice: true,
          supported_parameters: metadata[:supported_parameters])
      end

      protected

      def endpoint
        "models/#{URI.encode_www_form_component(model)}:streamGenerateContent?alt=sse&key=#{URI.encode_www_form_component(@api_key)}"
      end

      def request_headers(_request) = {"content-type" => "application/json", "accept" => "text/event-stream"}

      private

      def request_body(request)
        system, messages = request.messages.partition { |message| message.role == :system }
        body = {contents: messages.map { |message| google_message(message) }}
        body[:systemInstruction] = {parts: system.flat_map { |message| message.content.grep(Content::Text).map { |block| {text: block.text} } }} unless system.empty?
        body[:tools] = [{functionDeclarations: request.tools.map { |tool| google_tool(tool) }}] unless request.tools.empty?
        body[:toolConfig] = google_tool_choice(request.tool_choice) if request.tool_choice
        generation = request.settings.to_h.transform_keys { |key| google_setting(key) }
        if request.output_schema
          generation[:responseMimeType] = "application/json"
          generation[:responseJsonSchema] = request.output_schema.fetch(:schema)
        end
        body[:generationConfig] = generation unless generation.empty?
        body
      end

      def google_setting(key)
        {max_tokens: :maxOutputTokens, top_p: :topP, top_k: :topK, stop_sequences: :stopSequences}[key.to_sym] || key.to_sym
      end

      def google_message(message)
        {role: (message.role == :assistant) ? "model" : "user", parts: message.content.map { |block| google_content(block) }}
      end

      def google_content(block)
        case block
        when Content::Text then {text: block.text}
        when Content::Image, Content::Document
          {inlineData: {mimeType: block.media_type, data: Base64.strict_encode64(block.data)}}
        when Content::ToolUse then {functionCall: {id: block.id, name: block.name, args: block.input}}
        when Content::ToolResult
          {functionResponse: {id: block.tool_use_id, name: block.tool_use_id, response: {output: Array(block.content).join("\n")}}}
        when Content::Reasoning then {text: block.text, thought: true}
        else raise ConfigurationError, "Unsupported Google content block: #{block.class}"
        end
      end

      def google_tool(tool)
        value = tool.is_a?(Hash) ? tool.transform_keys(&:to_sym) : {name: tool.name, description: tool.description, input_schema: tool.input_schema}
        {name: value.fetch(:name), description: value[:description], parametersJsonSchema: value[:input_schema] || {}}
      end

      def google_tool_choice(choice)
        return {functionCallingConfig: {mode: "ANY"}} if choice == :required

        {functionCallingConfig: {mode: "ANY", allowedFunctionNames: [choice.fetch(:name).to_s]}}
      end

      class Normalizer # :nodoc:
        def initialize(model:)
          @model = model
          @text = +""
          @reasoning = +""
          @tools = []
          @usage = Usage.new
          @started = false
          @terminal = false
        end

        def consume(event)
          raise ProviderError, "Google request failed: #{event.dig("error", "message")}" if event["error"]

          events = []
          unless @started
            @started = true
            events << StreamEvent.build(:message_start, id: nil, model: event["modelVersion"] || @model)
          end
          candidate = event.fetch("candidates", []).first
          if candidate
            candidate.dig("content", "parts")&.each { |part| events.concat(part_events(part)) }
            if candidate["finishReason"]
              @stop_reason = normalize_stop(candidate["finishReason"])
              @terminal = true
            end
          end
          if event["usageMetadata"]
            @usage = usage(event.fetch("usageMetadata"))
            events << StreamEvent.build(:usage, usage: @usage)
          end
          events
        end

        def finish
          raise ProtocolError, "Google stream ended before a finish reason" unless @terminal

          blocks = []
          blocks << Content::Reasoning.new(text: @reasoning) unless @reasoning.empty?
          blocks << Content::Text.new(text: @text) unless @text.empty?
          blocks.concat(@tools)
          response = ModelResponse.new(message: Message.new(role: :assistant, content: blocks),
            stop_reason: @stop_reason, usage: @usage, metadata: {model: @model})
          [StreamEvent.build(:message_stop, response:)]
        end

        private

        def part_events(part)
          if part["functionCall"]
            call = part.fetch("functionCall")
            index = @tools.length
            tool = Content::ToolUse.new(id: call["id"] || "call-#{index}", name: call.fetch("name"), input: call["args"] || {})
            @tools << tool
            [
              StreamEvent.build(:tool_call_start, index:, id: tool.id, name: tool.name),
              StreamEvent.build(:tool_call_stop, index:, tool_use: tool)
            ]
          elsif part["text"] && part["thought"]
            @reasoning << part["text"]
            [StreamEvent.build(:reasoning_delta, text: part["text"])]
          elsif part["text"]
            @text << part["text"]
            [StreamEvent.build(:text_delta, text: part["text"])]
          else
            []
          end
        end

        def usage(value)
          cached = value["cachedContentTokenCount"] || 0
          reasoning = value["thoughtsTokenCount"] || 0
          Usage.new(
            input_tokens: [Integer(value["promptTokenCount"] || 0) - Integer(cached), 0].max,
            output_tokens: [Integer(value["candidatesTokenCount"] || 0) - Integer(reasoning), 0].max,
            cache_read_tokens: cached,
            reasoning_tokens: reasoning
          )
        end

        def normalize_stop(value)
          case value
          when "MAX_TOKENS" then :max_tokens
          when "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII" then :content_filter
          else @tools.empty? ? :end_turn : :tool_use
          end
        end
      end
    end
  end
end
