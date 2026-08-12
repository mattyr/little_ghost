# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module LittleGhost
  module CatalogSources
    MAX_CATALOG_BYTES = 25 * 1024 * 1024
    MAX_ERROR_BYTES = 4 * 1024

    def self.get(uri, label:, headers: {}, max_bytes: MAX_CATALOG_BYTES)
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value unless value.to_s.empty? }
      body = +""
      status = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
        http.request(request) do |response|
          status = response.code.to_i
          limit = response.is_a?(Net::HTTPSuccess) ? max_bytes : MAX_ERROR_BYTES
          response.read_body do |chunk|
            raise ProviderError, "#{label} response exceeded #{limit} bytes" if body.bytesize + chunk.bytesize > limit

            body << chunk
          end
          unless response.is_a?(Net::HTTPSuccess)
            raise Providers::HTTPError.new("#{label} failed with HTTP #{response.code}", status:, body:)
          end
        end
      end
      body
    rescue *Providers::HTTPTransport::TRANSIENT_NETWORK_ERRORS => error
      raise Providers::HTTPError, "#{label} failed (#{error.class})"
    end

    # Refreshes normalized facts from the public models.dev catalog.
    class ModelsDev
      URL = URI("https://models.dev/api.json")
      NAMESPACES = {
        "openai" => "openai", "openrouter" => "openrouter", "anthropic" => "anthropic",
        "gemini" => "google", "vertex_ai" => "google-vertex", "bedrock" => "amazon-bedrock"
      }.freeze

      attr_reader :name

      def initialize(provider_adapters:, http_get: nil)
        @provider_adapters = provider_adapters.to_h.transform_keys(&:to_s)
        @http_get = http_get || method(:http_get)
        @name = "models.dev"
      end

      def refresh(target: nil)
        document = JSON.parse(@http_get.call(URL))
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

      def http_get(uri)
        CatalogSources.get(uri, label: "models.dev request")
      end
    end

    # Adds richer routing metadata and pricing from OpenRouter's live catalog.
    class OpenRouter
      URL = URI("https://openrouter.ai/api/v1/models")
      attr_reader :name

      def initialize(provider:, api_key:, http_get: nil)
        @provider = provider
        @api_key = api_key
        @http_get = http_get || method(:http_get)
        @name = "openrouter"
      end

      def refresh(target: nil)
        values = JSON.parse(@http_get.call(URL, @api_key)).fetch("data")
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

      private

      def http_get(uri, api_key)
        CatalogSources.get(uri, headers: {"Authorization" => "Bearer #{api_key}"}, label: "OpenRouter catalog")
      end
    end

    # Enriches availability and limits from Anthropic's model list endpoint.
    class Anthropic
      URL = URI("https://api.anthropic.com/v1/models")
      attr_reader :name

      def initialize(provider:, api_key:, http_get: nil)
        @provider = provider
        @api_key = api_key
        @http_get = http_get || method(:http_get)
        @name = "anthropic"
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
        CatalogSources.get(uri, headers: {"x-api-key" => api_key, "anthropic-version" => "2023-06-01"}, label: "Anthropic catalog")
      end
    end

    # Enriches Gemini availability and limits from the Developer API.
    class Gemini
      URL = URI("https://generativelanguage.googleapis.com/v1beta/models")
      attr_reader :name

      def initialize(provider:, api_key:, http_get: nil)
        @provider = provider
        @api_key = api_key
        @http_get = http_get || method(:http_get)
        @name = "gemini"
      end

      def refresh(target: nil)
        uri = URI("#{URL}?key=#{URI.encode_www_form_component(@api_key)}")
        values = JSON.parse(@http_get.call(uri)).fetch("models")
        values.select! { |value| value["name"].to_s.delete_prefix("models/") == target.model_id } if target
        values.to_h do |value|
          id = value.fetch("name").delete_prefix("models/")
          ["#{@provider}:#{id}", {available: true, context_window: value["inputTokenLimit"],
                                  max_output_tokens: value["outputTokenLimit"]}.compact]
        end
      rescue JSON::ParserError, KeyError => error
        raise ProviderError, "Gemini returned an invalid catalog: #{error.message}"
      end

      private

      def http_get(uri)
        CatalogSources.get(uri, label: "Gemini catalog")
      end
    end

    # Enriches Bedrock availability from ListFoundationModels using SigV4.
    class Bedrock
      attr_reader :name

      def initialize(provider:, region:, credential_resolver: nil, http_get: nil, clock: -> { Time.now.utc })
        @provider = provider
        @region = region
        @credential_resolver = credential_resolver || Providers::AwsCredentialResolver.new
        @http_get = http_get || method(:http_get)
        @clock = clock
        @name = "bedrock"
      end

      def refresh(target: nil)
        uri = URI("https://bedrock.#{@region}.amazonaws.com/foundation-models")
        credentials = @credential_resolver.call
        headers = Providers::AwsSigV4.new(service: "bedrock", region: @region, credentials:, clock: @clock)
          .headers(method: :get, uri:, headers: {}, body: "")
        values = JSON.parse(@http_get.call(uri, headers)).fetch("modelSummaries")
        values.select! { |value| value["modelId"] == target.model_id } if target
        values.to_h do |value|
          ["#{@provider}:#{value.fetch("modelId")}", {available: true,
                                                      input_modalities: value["inputModalities"]&.map(&:downcase),
                                                      output_modalities: value["outputModalities"]&.map(&:downcase)}.compact]
        end
      rescue JSON::ParserError, KeyError => error
        raise ProviderError, "Bedrock returned an invalid catalog: #{error.message}"
      end

      private

      def http_get(uri, headers)
        CatalogSources.get(uri, headers:, label: "Bedrock catalog")
      end
    end
  end
end
