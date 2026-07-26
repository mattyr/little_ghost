# frozen_string_literal: true

require "json"
require "test_helper"

class StructuredResultsTest < Minitest::Test
  class ScriptedModel
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
      @mutex = Mutex.new
    end

    def stream(request)
      response = @mutex.synchronize do
        @requests << request
        @responses.shift
      end
      [LittleGhost::StreamEvent.build(:message_stop, response:)].each
    end
  end

  def test_result_schema_uses_native_output_schema_and_returns_the_value
    model = ScriptedModel.new(response(JSON.generate("answer" => "forty-two")))
    agent = structured_agent.new(model:)

    result = agent.call("question")

    assert result.structured?
    assert_equal :structured_result, result.stop_reason
    assert_equal "investigation_result", result.structured_result.schema_name
    assert_equal({"answer" => "forty-two"}, result.structured_result.value)
    assert_equal "investigation_result", model.requests.first.output_schema.fetch(:name)
    assert_empty model.requests.first.tools
    assert_equal %i[user assistant], result.messages.map(&:role)
    refute_includes result.messages.map(&:to_h).inspect, "forty-two"
    assert_includes result.message.text, "Structured result investigation_result redacted"
  ensure
    agent&.close
  end

  def test_missing_submission_gets_one_repair_turn
    model = ScriptedModel.new(
      response("plain text"),
      response(JSON.generate("answer" => "repaired"))
    )
    agent = structured_agent.new(model:)

    result = agent.call("question")

    assert_equal({"answer" => "repaired"}, result.structured_result.value)
    assert_equal 2, model.requests.length
    assert_includes model.requests.last.messages.last.text, "one repair attempt"
  ensure
    agent&.close
  end

  def test_invalid_result_gets_one_repair_turn
    model = ScriptedModel.new(
      response(JSON.generate("wrong" => "shape")),
      response(JSON.generate("answer" => "repaired"))
    )
    agent = structured_agent.new(model:)

    result = agent.call("question")

    assert_equal({"answer" => "repaired"}, result.structured_result.value)
    assert_includes model.requests.last.messages.last.text, "one repair attempt"
    refute_includes model.requests.last.messages.map(&:to_h).inspect, "shape"
  ensure
    agent&.close
  end

  def test_malformed_json_does_not_leak_payload_fragments_into_repair_or_telemetry
    secret = "customer@example.com"
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true),
      subscribers: [->(name, attributes) { telemetry << [name, attributes] }]
    )
    model = ScriptedModel.new(
      response(%({"answer":"#{secret})),
      response(JSON.generate("answer" => "repaired"))
    )
    agent = structured_agent.new(model:, instrumentation:)

    result = agent.call("question")

    assert_equal({"answer" => "repaired"}, result.structured_result.value)
    refute_includes model.requests.last.messages.map(&:to_h).inspect, secret
    refute_includes telemetry.inspect, secret
  ensure
    agent&.close
  end

  def test_second_invalid_result_raises_a_typed_failure
    model = ScriptedModel.new(
      response(JSON.generate("wrong" => "shape")),
      response(JSON.generate("still" => "wrong"))
    )
    agent = structured_agent.new(model:)

    error = assert_raises(LittleGhost::StructuredResultError) { agent.call("question") }

    assert_equal "investigation_result", error.schema_name
    assert_includes error.validation_errors.join, "$.answer is required"
    assert_equal 2, model.requests.length
  ensure
    agent&.close
  end

  def test_native_output_schema_does_not_replace_working_tools
    side_effects = []
    side_effect = LittleGhost::Tool.define(name: "side_effect", description: "Mutate") do
      side_effects << true
      "changed"
    end
    model = ScriptedModel.new(
      response(
        LittleGhost::Content::ToolUse.new(id: "side-effect", name: "side_effect", input: {}),
        stop_reason: :tool_use
      ),
      response(JSON.generate("answer" => "complete"))
    )
    agent = structured_agent.new(model:, tools: [side_effect])

    result = agent.call("question")

    assert_equal [true], side_effects
    assert_equal({"answer" => "complete"}, result.structured_result.value)
    assert_equal %w[side_effect], model.requests.first.tools.map { |tool| tool.fetch(:name) }
  ensure
    agent&.close
  end

  def test_turn_limit_raises_a_typed_failure_when_repair_is_unavailable
    model = ScriptedModel.new(response("plain text"))
    agent = structured_agent.new(model:, max_turns: 1)

    error = assert_raises(LittleGhost::StructuredResultError) { agent.call("question") }

    assert_equal "investigation_result", error.schema_name
    assert_equal ["repair turn unavailable"], error.validation_errors
  ensure
    agent&.close
  end

  def test_oversized_results_receive_one_repair_and_then_fail_typed
    oversized = "x" * LittleGhost::Agent::MAX_STRUCTURED_RESULT_BYTES
    model = ScriptedModel.new(
      response(JSON.generate("answer" => oversized)),
      response(JSON.generate("answer" => oversized))
    )
    agent = structured_agent.new(model:)

    error = assert_raises(LittleGhost::StructuredResultError) { agent.call("question") }

    assert_includes error.validation_errors.join, "maximum serialized size"
    refute_includes model.requests.last.messages.map(&:to_h).inspect, oversized
  ensure
    agent&.close
  end

  def test_structured_result_is_propagated_by_agent_tools
    model = ScriptedModel.new(response(JSON.generate("answer" => "delegated")))
    child = structured_agent.new(model:)
    tool = child.as_tool(name: "investigate")

    result = tool.execute({"input" => "question"})

    assert result.success?
    assert_equal({"answer" => "delegated"}, JSON.parse(result.content))
  ensure
    tool&.close
  end

  def test_structured_result_telemetry_excludes_the_payload
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })
    model = ScriptedModel.new(response(JSON.generate("answer" => "private")))
    agent = structured_agent.new(model:, instrumentation:)

    agent.call("question")

    event = telemetry.find { |name, _attributes| name == :structured_result }.last
    assert_equal "investigation_result", event.fetch(:schema_name)
    assert_equal :valid, event.fetch(:validation_status)
    assert_equal false, event.fetch(:repair_attempted)
    assert event.key?(:duration_ms)
    assert event.key?(:result_duration_ms)
    assert event.key?(:input_tokens)
    refute_includes telemetry.inspect, "private"
  ensure
    agent&.close
  end

  def test_agents_can_disable_diagnostic_content_capture
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true),
      subscribers: [->(name, attributes) { telemetry << [name, attributes] }]
    )
    agent_class = Class.new(structured_agent) { capture_diagnostics false }
    model = ScriptedModel.new(response(JSON.generate("answer" => "private")))
    agent = agent_class.new(model:, instrumentation:)

    agent.call(
      LittleGhost::Message.new(
        role: :user,
        content: "customer evidence",
        metadata: {diagnostic_redact: true}
      )
    )

    refute_includes telemetry.inspect, "customer evidence"
    refute_includes telemetry.inspect, "private"
  ensure
    agent&.close
  end

  def test_result_schema_is_inherited_and_requires_an_object
    parent = structured_agent
    child = Class.new(parent)

    assert_equal parent.result_schema, child.result_schema
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) { result_schema(type: "array", items: {type: "string"}) }
    end
    error = assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          type: "object",
          properties: {decision: {type: "string", const: "allow"}},
          required: ["decision"],
          additionalProperties: false
        )
      end
    end
    assert_includes error.message, "$.properties.decision"
    assert_includes error.message, "const"
    tuple_error = assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          type: "object",
          properties: {
            values: {
              type: "array",
              items: [{type: "string"}, {type: "integer"}]
            }
          },
          required: ["values"],
          additionalProperties: false
        )
      end
    end
    assert_includes tuple_error.message, "$.properties.values"
    assert_includes tuple_error.message, "items must be an object schema"
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          type: "object",
          properties: {confidence: {type: "string", enum: [:high]}},
          required: ["confidence"],
          additionalProperties: false
        )
      end
    end
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          type: "object",
          properties: {score: {type: "number", maximum: Float::NAN}},
          required: ["score"],
          additionalProperties: false
        )
      end
    end
    optional_error = assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          type: "object",
          properties: {answer: {type: "string"}},
          required: [],
          additionalProperties: false
        )
      end
    end
    assert_includes optional_error.message, "require every property"
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) do
        result_schema(
          {
            type: "object",
            properties: {answer: {type: "string"}},
            required: ["answer"],
            additionalProperties: false
          },
          name: "invalid schema name"
        )
      end
    end
  end

  private

  def structured_agent
    Class.new(LittleGhost::Agent) do
      result_schema(
        {
          type: "object",
          properties: {answer: {type: "string"}},
          required: ["answer"],
          additionalProperties: false
        },
        name: "investigation_result"
      )
    end
  end

  def response(content, stop_reason: :end_turn)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:,
      usage: LittleGhost::Usage.new(input_tokens: 2, output_tokens: 1)
    )
  end
end
