# frozen_string_literal: true

require "test_helper"

class BedrockCatalogSourceTest < Minitest::Test
  Credentials = LittleGhost::Providers::Bedrock::Credentials

  class FakeHTTPClient
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def request(**request)
      @requests << request
      @responses.shift || raise("unexpected request")
    end
  end

  def test_refresh_enriches_regional_model_pricing_across_pages
    client = FakeHTTPClient.new([
      JSON.generate(modelSummaries: [{modelId: "anthropic.claude-test", modelName: "Claude Test",
                                      inputModalities: ["TEXT"], outputModalities: ["TEXT"]}]),
      pricing_page([pricing_product("Claude Test", "us-west-2", "Input tokens", "0.003")], next_token: "page-2"),
      pricing_page([pricing_product("Claude Test", "us-west-2", "Output tokens", "0.015")])
    ])
    source = source(client:)
    catalog = LittleGhost::Models::Catalog.new(sources: [source])

    result = catalog.refresh!(target: "aws:anthropic.claude-test")
    details = catalog.details("aws:anthropic.claude-test")

    assert_empty result.fetch(:errors)
    assert_equal({input: 3.0, output: 15.0}, details.pricing)
    assert_equal ["text"], details.input_modalities
    assert_equal "aws_pricing", details.provenance.fetch(:pricing)
    assert_equal "bedrock", details.provenance.fetch(:available)
    pricing_requests = client.requests.select { |request| request[:uri].host == "api.pricing.us-east-1.amazonaws.com" }
    assert_equal 2, pricing_requests.length
    assert pricing_requests.all? { |request| request[:headers].fetch("authorization").include?("/us-east-1/pricing/aws4_request") }
    assert_equal "page-2", JSON.parse(pricing_requests.last.fetch(:body)).fetch("NextToken")
  end

  def test_global_target_requests_global_pricing_for_the_base_model
    client = FakeHTTPClient.new([
      JSON.generate(modelSummaries: [{modelId: "amazon.nova-test", modelName: "Nova Test",
                                      inputModalities: ["TEXT"], outputModalities: ["TEXT"]}]),
      pricing_page([
        pricing_product("Nova Test", "us-west-2", "Global Input tokens", "2.00", unit: "1M tokens"),
        pricing_product("Nova Test", "us-west-2", "Global Output tokens", "4.00", unit: "1M tokens")
      ])
    ])
    source = source(client:)

    records = source.refresh(target: LittleGhost::Models::Target.parse("aws:global.amazon.nova-test"))

    assert_equal 2.0, records.dig("aws:global.amazon.nova-test", :pricing, :input)
    pricing_body = JSON.parse(client.requests.last.fetch(:body))
    region_filter = pricing_body.fetch("Filters").find { |filter| filter.fetch("Field") == "regionCode" }
    assert_equal "us-west-2", region_filter.fetch("Value")
    assert_equal "AmazonBedrockFoundationModels", pricing_body.fetch("ServiceCode")
  end

  def test_refresh_falls_back_to_the_bedrock_offer
    client = FakeHTTPClient.new([
      JSON.generate(modelSummaries: [{modelId: "amazon.nova-test", modelName: "Nova Test"}]),
      pricing_page([]),
      pricing_page([
        pricing_product("Nova Test", "us-west-2", "Input tokens", "0.001"),
        pricing_product("Nova Test", "us-west-2", "Output tokens", "0.002")
      ])
    ])
    source = source(client:)

    records = source.refresh(target: LittleGhost::Models::Target.parse("aws:amazon.nova-test"))

    assert_equal({input: 1.0, output: 2.0}, records.dig("aws:amazon.nova-test", :pricing))
    pricing_bodies = client.requests.drop(1).map { |request| JSON.parse(request.fetch(:body)) }
    assert_equal %w[AmazonBedrockFoundationModels AmazonBedrock], pricing_bodies.map { |body| body.fetch("ServiceCode") }
    assert_equal %w[servicename model], pricing_bodies.map { |body| body.fetch("Filters").last.fetch("Field") }
  end

  def test_refresh_rejects_repeated_pricing_pagination_tokens
    client = FakeHTTPClient.new([
      JSON.generate(modelSummaries: [{modelId: "anthropic.claude-test", modelName: "Claude Test"}]),
      pricing_page([], next_token: "repeat"),
      pricing_page([], next_token: "repeat")
    ])

    error = assert_raises(LittleGhost::ProviderError) do
      source(client:).refresh(target: LittleGhost::Models::Target.parse("aws:anthropic.claude-test"))
    end

    assert_equal "AWS pricing pagination repeated a token", error.message
  end

  private

  def source(client:)
    credentials = Credentials.new(access_key_id: "key", secret_access_key: "secret")
    LittleGhost::Providers::Bedrock::CatalogSource.new(
      provider: "aws",
      region: "us-west-2",
      credential_resolver: -> { credentials },
      clock: -> { Time.utc(2026, 8, 12) },
      http_client: client
    )
  end

  def pricing_page(products, next_token: nil)
    JSON.generate({PriceList: products.map { |product| JSON.generate(product) }}.tap do |page|
      page[:NextToken] = next_token if next_token
    end)
  end

  def pricing_product(model, region, description, amount, unit: "1K tokens")
    {
      product: {attributes: {
        model: model,
        regionCode: region,
        usagetype: description,
        inferenceType: description.include?("Global") ? "Cross-Region On Demand" : "On Demand"
      }},
      terms: {OnDemand: {"term" => {priceDimensions: {"dimension" => {
        description: description, unit: unit, pricePerUnit: {USD: amount}
      }}}}}
    }
  end
end
