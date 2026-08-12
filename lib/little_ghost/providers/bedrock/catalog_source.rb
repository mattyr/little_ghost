# frozen_string_literal: true

module LittleGhost
  module Providers
    class Bedrock < Base
      # Enriches Bedrock availability from ListFoundationModels using SigV4.
      class CatalogSource < Models::Catalog::Source
        attr_reader :name

        def initialize(provider:, region:, credential_resolver: nil, clock: -> { Time.now.utc })
          super(name: "bedrock")
          @provider = provider
          @region = region
          @credential_resolver = credential_resolver || CredentialResolver.new
          @clock = clock
        end

        def refresh(target: nil)
          uri = URI("https://bedrock.#{@region}.amazonaws.com/foundation-models")
          credentials = @credential_resolver.call
          headers = AwsSigV4.new(service: "bedrock", region: @region, credentials:, clock: @clock)
            .headers(method: :get, uri:, headers: {}, body: "")
          values = JSON.parse(
            Support::HTTPClient.new(open_timeout: 5, read_timeout: 30, max_response_bytes: 25 * 1024 * 1024)
              .request(uri:, headers:)
          ).fetch("modelSummaries")
          values.select! { |value| value["modelId"] == target.model_id } if target
          values.to_h do |value|
            ["#{@provider}:#{value.fetch("modelId")}", {available: true,
                                                        input_modalities: value["inputModalities"]&.map(&:downcase),
                                                        output_modalities: value["outputModalities"]&.map(&:downcase)}.compact]
          end
        rescue JSON::ParserError, KeyError => error
          raise ProviderError, "Bedrock returned an invalid catalog: #{error.message}"
        end
      end
    end
  end
end
