# frozen_string_literal: true

module LittleGhost
  module Providers
    class Anthropic < Base
      # Enriches availability and limits from Anthropic's model list endpoint.
      class CatalogSource < Models::Catalog::Source
        URL = URI("https://api.anthropic.com/v1/models")
        attr_reader :name

        def initialize(provider:, api_key:, http_get: nil)
          super(name: "anthropic")
          @provider = provider
          @api_key = api_key
          @http_get = http_get || method(:http_get)
        end

        def refresh(target: nil)
          values = JSON.parse(@http_get.call(URL, @api_key)).fetch("data")
          values.select! { |value| value["id"] == target.model_id } if target
          values.to_h { |value| ["#{@provider}:#{value.fetch("id")}", {available: true, observed_at: value["created_at"]}.compact] }
        rescue JSON::ParserError, KeyError => error
          raise ProviderError, "Anthropic returned an invalid catalog: #{error.message}"
        end

        private

        def http_get(uri, api_key)
          Support::HTTPClient.new(open_timeout: 5, read_timeout: 30, max_response_bytes: 25 * 1024 * 1024)
            .request(uri:, headers: {"x-api-key" => api_key, "anthropic-version" => "2023-06-01"})
        end
      end
    end
  end
end
