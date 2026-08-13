# frozen_string_literal: true

module LittleGhost
  module Providers
    class OpenRouter < OpenAICompatible
      # Adds richer routing metadata and pricing from OpenRouter's live catalog.
      class CatalogSource < Models::Catalog::Source
        URL = URI("https://openrouter.ai/api/v1/models") # :nodoc:

        # Creates a source for the named provider connection.
        def initialize(provider:, credential_resolver:)
          super(name: "openrouter")
          @provider = provider
          @credential_resolver = credential_resolver
        end

        def refresh(target: nil)
          api_key = @credential_resolver.call.fetch("api_key")
          values = JSON.parse(
            Support::HTTPClient.new(open_timeout: 5, read_timeout: 30, max_response_bytes: 25 * 1024 * 1024)
              .request(uri: URL, headers: {"Authorization" => "Bearer #{api_key}"})
          ).fetch("data")
          values.select! { |value| value["id"] == target.model_id } if target
          values.to_h do |value|
            pricing = value.fetch("pricing", {}).each_with_object({}) do |(key, amount), result|
              normalized = {"prompt" => :input, "completion" => :output, "input_cache_read" => :cache_read,
                            "input_cache_write" => :cache_write}[key]
              result[normalized] = Float(amount) * 1_000_000 if normalized
            end
            ["#{@provider}:#{value.fetch("id")}", {
              context_window: value["context_length"], max_output_tokens: value.dig("top_provider", "max_completion_tokens"),
              supported_parameters: value["supported_parameters"], input_modalities: value.dig("architecture", "input_modalities"),
              output_modalities: value.dig("architecture", "output_modalities"), pricing:
            }.compact]
          end
        rescue JSON::ParserError, KeyError, ArgumentError => error
          raise ProviderError, "OpenRouter returned an invalid catalog: #{error.message}"
        end
      end
    end
  end
end
