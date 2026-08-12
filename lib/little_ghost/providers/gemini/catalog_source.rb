# frozen_string_literal: true

module LittleGhost
  module Providers
    class Gemini < Base
      # Enriches Gemini availability and limits from the Developer API.
      class CatalogSource < Models::Catalog::Source
        URL = URI("https://generativelanguage.googleapis.com/v1beta/models") # :nodoc:

        # Creates a source for the named provider connection.
        def initialize(provider:, credential_resolver:)
          super(name: "gemini")
          @provider = provider
          @credential_resolver = credential_resolver
        end

        def refresh(target: nil)
          api_key = @credential_resolver.call.fetch("api_key")
          values = JSON.parse(
            Support::HTTPClient.new(open_timeout: 5, read_timeout: 30, max_response_bytes: 25 * 1024 * 1024)
              .request(uri: URL, headers: {"x-goog-api-key" => api_key})
          ).fetch("models")
          values.select! { |value| value["name"].to_s.delete_prefix("models/") == target.model_id } if target
          values.to_h do |value|
            id = value.fetch("name").delete_prefix("models/")
            ["#{@provider}:#{id}", {available: true, context_window: value["inputTokenLimit"],
                                    max_output_tokens: value["outputTokenLimit"]}.compact]
          end
        rescue JSON::ParserError, KeyError => error
          raise ProviderError, "Gemini returned an invalid catalog: #{error.message}"
        end
      end
    end
  end
end
