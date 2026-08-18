# frozen_string_literal: true

module LittleGhost
  # Constructs built-in and application provider adapters from named provider
  # connections. Register adapters during application configuration.
  class ProviderRegistry
    # :nodoc:
    REQUEST_OPTIONS = %i[
      app_name max_response_bytes max_retries max_retry_delay open_timeout read_timeout retries
    ].freeze
    # :nodoc:
    BUILT_INS = {
      "openai_compatible" => Providers::OpenAICompatible,
      "openai" => Providers::OpenAI,
      "openrouter" => Providers::OpenRouter,
      "anthropic" => Providers::Anthropic,
      "gemini" => Providers::Gemini,
      "vertex_ai" => Providers::VertexAI,
      "bedrock" => Providers::Bedrock
    }.freeze

    # Creates a registry with optional adapter factories keyed by adapter name.
    # Application adapters supplement the built-in provider adapters.
    def initialize(adapters: {})
      @adapters = BUILT_INS.merge(adapters.to_h.transform_keys(&:to_s))
    end

    # Constructs the configured provider for +model+.
    #
    # +configuration+ supplies the connection, including its endpoint and
    # credentials. The trusted +request+ mapping may change only the bounded
    # request options accepted by the selected adapter.
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
      if factory.is_a?(Class)
        unless factory <= Providers::Base
          raise AdapterLoadError, "Provider adapter #{adapter} must inherit LittleGhost::Providers::Base"
        end

        request_options.select! { |key| factory.request_options.include?(key) }
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
