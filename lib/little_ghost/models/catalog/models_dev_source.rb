# frozen_string_literal: true

require "json"
require "uri"

module LittleGhost
  module Models
    class Catalog
      MAX_CATALOG_BYTES = 25 * 1024 * 1024 # :nodoc:

      # Refreshes normalized facts from the public models.dev catalog.
      class ModelsDevSource < Source
        URL = URI("https://models.dev/api.json") # :nodoc:
        NAMESPACES = { # :nodoc:
          "openai" => "openai", "openrouter" => "openrouter", "anthropic" => "anthropic",
          "gemini" => "google", "vertex_ai" => "google-vertex", "bedrock" => "amazon-bedrock"
        }.freeze

        # Creates a source that maps application provider names to adapters.
        def initialize(provider_adapters:)
          super(name: "models.dev")
          @provider_adapters = provider_adapters.to_h.transform_keys(&:to_s)
        end

        # Fetches normalized model facts, optionally for one canonical +target+.
        def refresh(target: nil)
          document = JSON.parse(
            Support::HTTPClient.new(open_timeout: 5, read_timeout: 30, max_response_bytes: MAX_CATALOG_BYTES)
              .request(uri: URL)
          )
          providers = target ? [target.provider] : @provider_adapters.keys
          providers.each_with_object({}) do |provider, result|
            namespace = NAMESPACES[@provider_adapters[provider]]
            next unless namespace && document[namespace]

            models = document.fetch(namespace).fetch("models")
            selected = target ? models.slice(target.model_id) : models
            selected.each { |id, value| result["#{provider}:#{id}"] = normalize(value) }
          end
        rescue JSON::ParserError, KeyError => error
          raise ProviderError, "models.dev returned an invalid catalog: #{error.message}"
        end

        private

        def normalize(value)
          parameters = []
          parameters << "tools" if value["tool_call"]
          parameters << "structured_outputs" if value["structured_output"]
          parameters << "temperature" if value["temperature"]
          parameters << "reasoning" if value["reasoning"]
          {
            context_window: value.dig("limit", "context"), max_output_tokens: value.dig("limit", "output"),
            input_modalities: value.dig("modalities", "input"), output_modalities: value.dig("modalities", "output"),
            supported_parameters: parameters.empty? ? nil : parameters, pricing: value["cost"],
            observed_at: value["last_updated"] || value["release_date"]
          }.compact
        end
      end
    end
  end
end
