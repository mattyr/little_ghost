# frozen_string_literal: true

require_relative "openai_compatible"

module LittleGhost
  module Providers
    class OpenRouter < OpenAICompatible
      DEFAULT_BASE_URL = "https://openrouter.ai/api/v1/"
      TOP_LEVEL_CACHE_MODELS = ["anthropic/", "~anthropic/"].freeze
      MESSAGE_CACHE_MODELS = [
        "google/gemini",
        "qwen/qwen3-max",
        "qwen/qwen-plus",
        "qwen/qwen3.6-plus",
        "qwen/qwen3-coder-plus",
        "qwen/qwen3-coder-flash",
        "deepseek/deepseek-v3.2"
      ].freeze

      def initialize(site_url: nil, app_name: nil, base_url: DEFAULT_BASE_URL, **arguments)
        @site_url = site_url
        @app_name = app_name
        super(base_url:, api: :chat_completions, **arguments)
      end

      def capabilities(metadata: {})
        parameters = metadata[:supported_parameters] || metadata["supported_parameters"]
        return ModelCapabilities.unknown unless parameters.is_a?(Array)

        values = parameters.map(&:to_s)
        ModelCapabilities.new(
          native_structured_output: values.any? { |value| %w[structured_outputs response_format].include?(value) },
          tools: values.include?("tools"),
          tool_choice: values.include?("tool_choice"),
          supported_parameters: values
        )
      end

      def prepare_request(request, capabilities:)
        return request if request.required_capabilities.empty?
        return request unless capabilities.supported_parameters

        settings = filter_supported_settings(request.settings, capabilities)
        ModelRequest.new(
          messages: request.messages,
          tools: request.tools,
          settings:,
          output_schema: request.output_schema,
          tool_choice: request.tool_choice,
          required_capabilities: request.required_capabilities,
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        )
      end

      private

      MODEL_SETTING_PARAMETERS = {
        temperature: %w[temperature],
        top_p: %w[top_p],
        max_tokens: %w[max_tokens max_completion_tokens],
        max_completion_tokens: %w[max_completion_tokens max_tokens],
        stop: %w[stop],
        seed: %w[seed],
        reasoning: %w[reasoning reasoning_effort],
        reasoning_effort: %w[reasoning reasoning_effort]
      }.freeze

      def filter_supported_settings(settings, capabilities)
        result = settings.to_h.dup
        MODEL_SETTING_PARAMETERS.each do |setting, parameters|
          key = result.key?(setting) ? setting : setting.to_s
          next unless result.key?(key)

          result.delete(key) unless capabilities.supports_parameter?(*parameters)
        end
        max_tokens_key = result.key?(:max_tokens) ? :max_tokens : "max_tokens"
        if result.key?(max_tokens_key) &&
            !capabilities.supports_parameter?("max_tokens") &&
            capabilities.supports_parameter?("max_completion_tokens")
          result[result.key?(:max_tokens) ? :max_completion_tokens : "max_completion_tokens"] =
            result.delete(max_tokens_key)
        end
        result.freeze
      end

      def dynamic_headers(request)
        session_id = request.settings[:session_id] || request.settings["session_id"]
        compact_hash(
          "HTTP-Referer" => @site_url,
          "X-Title" => @app_name,
          "x-session-id" => session_id&.to_s&.slice(0, 256)
        )
      end

      def provider_settings(settings)
        result = super
        reasoning = settings[:reasoning] || settings["reasoning"]
        effort = settings[:reasoning_effort] || settings["reasoning_effort"]
        result[:reasoning] = reasoning || {effort:} if reasoning || effort
        session_id = settings[:session_id] || settings["session_id"]
        result[:session_id] = session_id.to_s.slice(0, 256) if session_id
        result[:cache_control] = {type: "ephemeral"} if model_prefix?(TOP_LEVEL_CACHE_MODELS)
        prompt_cache_key = settings[:prompt_cache_key] || settings["prompt_cache_key"]
        result[:prompt_cache_key] = prompt_cache_key if prompt_cache_key
        result
      end

      def chat_reasoning_fields(message)
        return {} unless message.role == :assistant

        blocks = message.content.grep(Content::Reasoning)
        text = blocks.map(&:text).reject(&:empty?).join
        details = blocks.flat_map { |block| Array(block.details) }
        compact_hash(
          reasoning: text.empty? ? nil : text,
          reasoning_details: details.empty? ? nil : details
        )
      end

      def request_body(request)
        body = super
        if request.output_schema || !request.required_capabilities.empty?
          body[:provider] = {require_parameters: true}
        end
        add_message_cache_control(body[:messages]) if model_prefix?(MESSAGE_CACHE_MODELS)
        body
      end

      def model_prefix?(prefixes)
        normalized = model.downcase
        prefixes.any? { |prefix| normalized.start_with?(prefix) }
      end

      def add_message_cache_control(messages)
        message = messages.find { |candidate| %w[system developer].include?(candidate[:role]) }
        return unless message

        content = message[:content]
        if content.is_a?(String)
          message[:content] = [{type: "text", text: content, cache_control: {type: "ephemeral"}}]
          return
        end

        block = Array(content).reverse.find { |candidate| candidate[:type] == "text" && !candidate.key?(:cache_control) }
        block[:cache_control] = {type: "ephemeral"} if block
      end
    end
  end
end
