# frozen_string_literal: true

require "test_helper"

class ModelOperationsTest < Minitest::Test
  class Provider < LittleGhost::Providers::Base
    attr_reader :requests

    def initialize(responses: [], embedding_response: nil)
      @responses = responses
      @embedding_response = embedding_response
      @requests = []
    end

    def stream(request)
      @requests << request
      response = @responses.shift
      yield LittleGhost::StreamEvent.build(:message_stop, response:)
    end

    def embed(request)
      @requests << request
      @embedding_response
    end

    def capabilities(metadata: {}) = LittleGhost::ModelCapabilities.permissive
  end

  Resolver = Data.define(:model) do
    def resolve(_selection) = model
  end

  class RejectingResolver
    def resolve(_selection) = raise("resolver must not be called")
  end

  def test_generates_plain_text_without_agent_lifecycle
    provider = Provider.new(responses: [model_response("Hello", input: 2, output: 1)])
    operations = operations_for(provider)

    result = operations.generate(model: :writer, messages: [{role: :user, content: "Hi"}])

    assert_equal "Hello", result.output
    refute result.structured?
    assert_equal :end_turn, result.stop_reason
    assert_equal %i[user assistant], result.messages.map(&:role)
    assert_empty result.state
    assert_empty result.steps
    assert_equal 2, result.usage.input_tokens
    assert_empty provider.requests.first.tools
  end

  def test_repairs_and_validates_a_structured_result_once
    provider = Provider.new(responses: [
      model_response("not json", input: 2, output: 1),
      model_response('{"answer":"yes"}', input: 4, output: 2)
    ])
    operations = operations_for(provider)

    result = operations.generate(
      model: :writer,
      messages: [{role: :user, content: "Answer"}],
      result_schema: result_schema
    )

    assert_equal({"answer" => "yes"}, result.output)
    assert result.structured?
    assert_equal :structured_result, result.stop_reason
    assert_equal "answer", result.structured_result.schema_name
    assert_equal %i[user assistant user assistant], result.messages.map(&:role)
    assert_equal "[Structured result answer redacted]", result.message.text
    assert_equal [
      "[Structured result answer redacted]",
      "[Structured result answer redacted]"
    ], result.messages.select { |message| message.role == :assistant }.map(&:text)
    assert_equal 6, result.usage.input_tokens
    assert_equal 2, provider.requests.length
    assert_equal "[Structured result answer redacted]", provider.requests.last.messages[-2].text
    refute provider.requests.last.messages.any? { |message| message.text.include?("not json") }
    assert_includes provider.requests.last.messages.last.text, "one repair attempt"
  end

  def test_redacts_a_valid_structured_result_without_a_repair
    provider = Provider.new(responses: [model_response('{"answer":"secret"}')])

    result = operations_for(provider).generate(
      model: :writer,
      messages: [{role: :user, content: "Answer"}],
      result_schema: result_schema
    )

    assert_equal({"answer" => "secret"}, result.output)
    assert_equal "[Structured result answer redacted]", result.text
    refute result.messages.any? { |message| message.text.include?("secret") }
  end

  def test_raises_after_one_invalid_structured_repair
    provider = Provider.new(responses: [model_response("bad"), model_response("still bad")])

    error = assert_raises(LittleGhost::StructuredResultError) do
      operations_for(provider).generate(model: :writer, messages: [], result_schema: result_schema)
    end

    assert_equal "answer", error.schema_name
    assert_equal 2, provider.requests.length
  end

  def test_embeds_with_profile_settings_and_preserves_order
    response = LittleGhost::Embeddings::Response.new(vectors: [[1, 0], [0, 1]], usage: LittleGhost::Usage.new(input_tokens: 3))
    provider = Provider.new(embedding_response: response)
    model = LittleGhost::Model.new(provider:, target: "test:embed", settings: {dimensions: 2}, role: :search)

    result = LittleGhost::ModelOperations.new(model_resolver: Resolver.new(model)).embed(
      model: :search, inputs: ["one", "two"]
    )

    assert_equal [[1.0, 0.0], [0.0, 1.0]], result.vectors
    assert_equal 2, result.dimensions
    assert_equal 2, provider.requests.first.settings[:dimensions]
    assert_equal "search", result.metadata[:model_role]
  end

  def test_rejects_empty_embedding_inputs
    assert_raises(ArgumentError) do
      LittleGhost::Embeddings::Request.new(inputs: [])
    end
  end

  def test_rejects_embedding_inputs_before_copying_when_limits_are_exceeded
    input = "large"

    assert_raises(LittleGhost::UnsupportedInputError) do
      LittleGhost::Embeddings::Request.new(inputs: [input, input], limits: {max_inputs: 1})
    end
    assert_raises(LittleGhost::UnsupportedInputError) do
      LittleGhost::Embeddings::Request.new(inputs: input, limits: {max_input_bytes: 4})
    end
    assert_raises(LittleGhost::UnsupportedInputError) do
      LittleGhost::Embeddings::Request.new(inputs: [input, input], limits: {max_total_bytes: 9})
    end
  end

  def test_rejects_oversized_inputs_before_resolving_a_provider
    operations = LittleGhost::ModelOperations.new(model_resolver: RejectingResolver.new)

    assert_raises(LittleGhost::UnsupportedInputError) do
      operations.embed(model: :search, inputs: "large", limits: {max_input_bytes: 4})
    end
  end

  def test_model_rejects_a_provider_vector_count_mismatch
    response = LittleGhost::Embeddings::Response.new(vectors: [[1, 0]])
    provider = Provider.new(embedding_response: response)
    model = LittleGhost::Model.new(provider:, target: "test:embed")

    assert_raises(LittleGhost::ProtocolError) do
      model.embed(LittleGhost::Embeddings::Request.new(inputs: ["one", "two"]))
    end
  end

  private

  def operations_for(provider)
    model = LittleGhost::Model.new(provider:, target: "test:writer", role: :writer)
    LittleGhost::ModelOperations.new(model_resolver: Resolver.new(model))
  end

  def model_response(text, input: 0, output: 0)
    LittleGhost::ModelResponse.new(
      message: {role: :assistant, content: text},
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens: input, output_tokens: output)
    )
  end

  def result_schema
    {
      name: "answer",
      schema: {
        type: "object",
        properties: {answer: {type: "string"}},
        required: ["answer"],
        additionalProperties: false
      }
    }
  end
end
