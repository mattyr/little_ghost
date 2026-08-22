# frozen_string_literal: true

require "test_helper"

class OpenAITest < Minitest::Test
  class Transport
    attr_reader :request

    def initialize(body)
      @body = body
    end

    def stream(**request)
      @request = request
      yield @body
    end
  end

  class ChunkedTransport < Transport
    def stream(**request)
      @request = request
      yield "x" * 6
      yield "y" * 6
    end
  end

  def test_batches_embeddings_and_restores_input_order
    transport = Transport.new(JSON.generate(
      model: "text-embedding-3-small",
      data: [
        {index: 1, embedding: [0, 1]},
        {index: 0, embedding: [1, 0]}
      ],
      usage: {prompt_tokens: 7}
    ))
    provider = LittleGhost::Providers::OpenAI.new(
      api_key: "secret", model: "text-embedding-3-small", transport:
    )

    result = provider.embed(LittleGhost::Embeddings::Request.new(
      inputs: ["first", "second"], settings: {dimensions: 2}
    ))

    assert_equal [[1.0, 0.0], [0.0, 1.0]], result.vectors
    assert_equal 7, result.usage.input_tokens
    request_body = JSON.parse(transport.request.fetch(:body))
    assert_equal ["first", "second"], request_body.fetch("input")
    assert_equal 2, request_body.fetch("dimensions")
  end

  def test_rejects_duplicate_embedding_indices
    transport = Transport.new(JSON.generate(
      data: [{index: 0, embedding: [1]}, {index: 0, embedding: [2]}]
    ))
    provider = LittleGhost::Providers::OpenAI.new(api_key: "secret", model: "embed", transport:)

    assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: ["first", "second"]))
    end
  end

  def test_rejects_an_embedding_response_over_its_byte_limit
    transport = ChunkedTransport.new("")
    provider = LittleGhost::Providers::OpenAI.new(
      api_key: "secret", model: "embed", transport:, max_embedding_response_bytes: 10
    )

    assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "first"))
    end
  end

  def test_rejects_vectors_with_unexpected_requested_dimensions
    transport = Transport.new(JSON.generate(data: [{index: 0, embedding: [1]}]))
    provider = LittleGhost::Providers::OpenAI.new(api_key: "secret", model: "embed", transport:)

    assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "first", settings: {dimensions: 2}))
    end
  end

  def test_invalid_embedding_index_does_not_leak_provider_content
    sentinel = "SENSITIVE_PROVIDER_FRAGMENT"
    transport = Transport.new(JSON.generate(data: [{index: sentinel, embedding: [1]}]))
    provider = LittleGhost::Providers::OpenAI.new(api_key: "secret", model: "embed", transport:)

    error = assert_raises(LittleGhost::ProtocolError) do
      provider.embed(LittleGhost::Embeddings::Request.new(inputs: "first"))
    end

    assert_equal "OpenAI returned an invalid embedding response", error.message
    refute_includes error.message, sentinel
  end
end
