# frozen_string_literal: true

module LittleGhost
  # Constructs built-in and application provider adapters from named provider
  # connections. Register adapters during application configuration.
  class ProviderRegistry
    REQUEST_OPTIONS = %i[
      app_name max_response_bytes max_retries max_retry_delay open_timeout read_timeout retries
    ].freeze
    BUILT_INS = {
      "openai_compatible" => Providers::OpenAICompatible,
      "openai" => Providers::OpenAI,
      "openrouter" => Providers::OpenRouter,
      "anthropic" => Providers::Anthropic,
      "gemini" => Providers::Gemini,
      "vertex_ai" => Providers::VertexAI,
      "bedrock" => Providers::Bedrock
    }.freeze

    def initialize(adapters: {})
      @adapters = BUILT_INS.merge(adapters.to_h.transform_keys(&:to_s))
    end

    def build(adapter:, model:, configuration:, request: {}, **context)
      factory = @adapters.fetch(adapter.to_s) do
        raise AdapterLoadError, "Unknown provider adapter: #{adapter}"
      end
      options = symbolize(configuration).reject { |key, value| key == :adapter || value.nil? }
      request_options = symbolize(request).reject { |_key, value| value.nil? }
      unsupported = request_options.keys - REQUEST_OPTIONS
      unless unsupported.empty?
        raise ConfigurationError, "Unsupported request options for #{adapter}: #{unsupported.join(", ")}"
      end
      if request_options.key?(:retries)
        request_options[:max_retries] ||= request_options[:retries]
        request_options.delete(:retries)
      end
      options.merge!(request_options)
      provider = if factory.is_a?(Class)
        factory.new(model:, **options)
      else
        factory.call(model:, configuration: options, **context)
      end
      unless provider.is_a?(Providers::Base)
        raise AdapterLoadError, "Provider adapter #{adapter} must return a LittleGhost::Providers::Base"
      end

      provider
    rescue ArgumentError => error
      raise unless error.message.match?(/unknown keyword|missing keyword/)

      raise ConfigurationError, "Invalid configuration for #{adapter}: #{error.message}"
    end

    private

    def symbolize(value) = value.to_h { |key, child| [key.to_sym, child] }
  end
end
