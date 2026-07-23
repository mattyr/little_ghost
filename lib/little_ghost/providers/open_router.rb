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

      private

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
