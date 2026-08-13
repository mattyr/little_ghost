# frozen_string_literal: true

module LittleGhost
  module Providers
    class Bedrock < Base
      # Enriches Bedrock availability and on-demand pricing using bounded,
      # SigV4-signed AWS APIs.
      class CatalogSource < Models::Catalog::Source
        PRICING_ENDPOINT = URI("https://api.pricing.us-east-1.amazonaws.com") # :nodoc:
        PRICING_REGION = "us-east-1" # :nodoc:
        MAX_PRICING_PAGES = 10 # :nodoc:
        MAX_RESULTS = 100 # :nodoc:
        FOUNDATION_MODEL_OFFER = "AmazonBedrockFoundationModels" # :nodoc:
        BEDROCK_OFFER = "AmazonBedrock" # :nodoc:
        ATTRIBUTE_MERGE_STRATEGIES = {input_modalities: :union}.freeze # :nodoc:

        # Creates a source for one Bedrock provider connection and AWS region.
        def initialize(provider:, region:, credential_resolver: nil, clock: -> { Time.now.utc }, http_client: nil)
          super(name: "bedrock")
          @provider = provider
          @region = region
          @credential_resolver = credential_resolver || CredentialResolver.new
          @clock = clock
          @http_client = http_client || Support::HTTPClient.new(
            open_timeout: 5,
            read_timeout: 30,
            max_response_bytes: 25 * 1024 * 1024
          )
        end

        # AWS reports a coarse subset of Converse input capabilities, so live
        # modalities augment richer facts supplied by another catalog source.
        def attribute_merge_strategies = ATTRIBUTE_MERGE_STRATEGIES

        def refresh(target: nil)
          credentials = @credential_resolver.call
          models = foundation_models(credentials, target:)
          products = (target && models.one?) ? pricing_products(credentials, models.first) : []
          records(models, products, target:)
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError => error
          raise ProviderError, "Bedrock returned an invalid catalog: #{error.message}"
        end

        private

        def foundation_models(credentials, target:)
          uri = URI("https://bedrock.#{@region}.amazonaws.com/foundation-models")
          values = JSON.parse(request(uri:, service: "bedrock", region: @region, credentials:))
            .fetch("modelSummaries")
          model_id = base_model_id(target.model_id) if target
          values.select! { |value| value["modelId"] == model_id } if model_id
          values
        end

        def pricing_products(credentials, model)
          products = pricing_products_for(
            credentials,
            service_code: FOUNDATION_MODEL_OFFER,
            filters: pricing_filters("servicename", "#{model.fetch("modelName")} (Amazon Bedrock Edition)")
          )
          return products unless products.empty?

          pricing_products_for(
            credentials,
            service_code: BEDROCK_OFFER,
            filters: pricing_filters("model", model.fetch("modelName"))
          )
        end

        def pricing_products_for(credentials, service_code:, filters:)
          products = []
          next_token = nil
          seen_tokens = {}

          MAX_PRICING_PAGES.times do
            body = pricing_request(service_code:, filters:, next_token:)
            uri = URI.join(PRICING_ENDPOINT.to_s, "/")
            response = JSON.parse(request(
              uri:,
              method: :post,
              service: "pricing",
              region: PRICING_REGION,
              credentials:,
              headers: {
                "content-type" => "application/x-amz-json-1.1",
                "x-amz-target" => "AWSPriceListService.GetProducts"
              },
              body:
            ))
            products.concat(response.fetch("PriceList").map { |value| JSON.parse(value) })
            next_token = response["NextToken"]
            break if next_token.to_s.empty?
            raise ProviderError, "AWS pricing pagination repeated a token" if seen_tokens[next_token]

            seen_tokens[next_token] = true
          end
          raise ProviderError, "AWS pricing exceeded #{MAX_PRICING_PAGES} pages" unless next_token.to_s.empty?

          products
        rescue HTTPError => error
          raise unless error.status == 400 && error.body.to_s.include?("InvalidParameter")

          []
        end

        def pricing_filters(field, value)
          [
            {"Type" => "TERM_MATCH", "Field" => "regionCode", "Value" => @region},
            {"Type" => "TERM_MATCH", "Field" => field, "Value" => value}
          ]
        end

        def pricing_request(service_code:, filters:, next_token:)
          request = {
            "ServiceCode" => service_code,
            "FormatVersion" => "aws_v1",
            "MaxResults" => MAX_RESULTS,
            "Filters" => filters
          }
          request["NextToken"] = next_token if next_token
          JSON.generate(request)
        end

        def request(uri:, service:, region:, credentials:, method: :get, headers: {}, body: "")
          signed_headers = AwsSigV4.new(service:, region:, credentials:, clock: @clock)
            .headers(method:, uri:, headers:, body:)
          @http_client.request(uri:, method:, headers: signed_headers, body: (body unless body.empty?))
        end

        def records(models, products, target:)
          models.to_h do |model|
            model_id = model.fetch("modelId")
            selected_id = target&.model_id || model_id
            pricing = normalized_prices(products, selected_id)
            attributes = {
              available: true,
              input_modalities: model["inputModalities"]&.map(&:downcase),
              output_modalities: model["outputModalities"]&.map(&:downcase),
              pricing:
            }.compact
            provenance = attributes.keys.to_h { |key| [key, (key == :pricing) ? "aws_pricing" : name] }
            ["#{@provider}:#{selected_id}", attributes.merge(provenance:)]
          end
        end

        def normalized_prices(products, model_id)
          global_pricing = model_id.to_s.match?(/\A(?:global|us|eu|apac)\./)
          prices = products.each_with_object({}) do |product, result|
            attributes = product.fetch("product").fetch("attributes")
            kind = price_kind(attributes, global_pricing:)
            next unless kind

            dimensions = product.fetch("terms").fetch("OnDemand", {}).values.flat_map do |term|
              term.fetch("priceDimensions", {}).values
            end
            result[kind] ||= normalized_price(dimensions.first) if dimensions.first
          end
          prices if prices.key?(:input) && prices.key?(:output)
        end

        def price_kind(attributes, global_pricing:)
          value = "#{attributes["usagetype"]} #{attributes["inferenceType"]}".downcase
          return if value.match?(/batch|priority|flex|reserved|tpm/) || !value.include?("token")

          global = value.match?(/global|cross-region/)
          return if global_pricing != global

          if value.include?("cache") && value.include?("read")
            :cache_read
          elsif value.include?("cache") && value.include?("write")
            :cache_write
          elsif value.match?(/(?:\b|_)output(?:token| tokens)/)
            :output
          elsif value.match?(/(?:\b|_)input(?:token| tokens)/) && !value.match?(/image|audio|video/)
            :input
          end
        end

        def normalized_price(dimension)
          amount = Float(dimension.fetch("pricePerUnit").fetch("USD"))
          unit = dimension.fetch("unit").downcase
          description = dimension["description"].to_s.downcase
          if unit.match?(/1m|million/) || description.match?(/(?:1,000,000|million)\s+tokens/)
            amount
          elsif unit.match?(/1k|thousand/) || description.match?(/(?:1,000|thousand)\s+tokens/)
            amount * 1_000
          elsif unit.include?("token")
            amount * 1_000_000
          else
            raise ArgumentError, "unsupported Bedrock pricing unit #{dimension.fetch("unit")}"
          end
        end

        def base_model_id(model_id)
          model_id.to_s.sub(/\A(?:global|us|eu|apac)\./, "")
        end
      end
    end
  end
end
