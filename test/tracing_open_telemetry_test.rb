# frozen_string_literal: true

require "test_helper"

class TracingOpenTelemetryTest < Minitest::Test
  Context = Struct.new(:trace_id) do
    def valid? = true
    def hex_trace_id = format("%032x", trace_id)
  end

  class Span
    attr_reader :attributes, :events, :context, :kind
    attr_accessor :status

    def initialize(attributes = {}, kind: nil)
      @attributes = attributes.dup
      @events = []
      @context = Context.new(123)
      @kind = kind
      @finished = false
    end

    def set_attribute(name, value) = attributes[name] = value
    def add_event(name, attributes:) = events << [name, attributes]
    def finish = @finished = true
    def finished? = @finished
  end

  class Tracer
    attr_reader :started, :instant

    def initialize
      @started = []
      @instant = []
    end

    def start_span(name, with_parent: nil, kind: nil, attributes: {})
      Span.new(attributes, kind:).tap { |span| started << [name, with_parent, span] }
    end

    def in_span(name, attributes:)
      instant << [name, attributes]
      yield Span.new(attributes)
    end
  end

  def test_fuses_the_primary_agent_into_the_root_and_nests_turns_and_models
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(
      :run_start,
      {
        operation_id: "run",
        run_id: "run-1",
        session_id: "session-1",
        agent_id: "main",
        agent_name: "Atlas Main",
        diagnostic_input: JSON.generate("hello")
      }
    )
    tracing.call(
      :agent_start,
      {
        operation_id: "agent",
        parent_operation_id: "run",
        agent_id: "main",
        agent_name: "Atlas Main",
        available_tools: %w[lookup fetch]
      }
    )
    tracing.call(:agent_turn_start, {operation_id: "turn", parent_operation_id: "agent", turn: 1})
    tracing.call(
      :model_start,
      {
        operation_id: "model",
        parent_operation_id: "turn",
        model_id: "model-1",
        model_provider: :openrouter,
        model_settings: {temperature: 0.2},
        diagnostic_tool_definitions: JSON.generate(
          [{name: "lookup", description: "Look up a value", input_schema: {type: "object"}}]
        ),
        diagnostic_input: JSON.generate([{role: "system", content: [{type: "text", text: "instructions"}]}])
      }
    )
    tracing.call(
      :model_stop,
      {
        operation_id: "model",
        outcome: :completed,
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 21,
        cache_read_tokens: 3,
        cache_write_tokens: 1,
        reasoning_tokens: 2,
        time_to_first_token: 0.0125,
        response_id: "response-1",
        response_model: "model-1",
        finish_reasons: ["stop"],
        diagnostic_output: JSON.generate(
          role: "assistant",
          content: [{type: "text", text: "done"}]
        )
      }
    )
    tracing.call(:agent_turn_stop, {operation_id: "turn", outcome: :completed})
    tracing.call(:agent_stop, {operation_id: "agent", outcome: :completed})
    trace_context = tracing.trace_context(operation_id: "run")
    tracing.call(
      :run_stop,
      {
        operation_id: "run",
        outcome: :completed,
        diagnostic_output: JSON.generate("done"),
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 21,
        cache_read_tokens: 3,
        cache_write_tokens: 1,
        reasoning_tokens: 2
      }
    )

    root_name, root_context, root_span = tracer.started.fetch(0)
    turn_name, turn_context, turn_span = tracer.started.fetch(1)
    model_name, model_context, model_span = tracer.started.fetch(2)
    assert_equal "invoke_agent Atlas Main", root_name
    assert_nil root_context
    assert_equal :internal, root_span.kind
    assert_equal "AGENT", root_span.attributes.fetch("openinference.span.kind")
    assert_equal "session-1", root_span.attributes.fetch("session.id")
    assert_equal "session-1", root_span.attributes.fetch("gen_ai.conversation.id")
    assert_equal JSON.generate("hello"), root_span.attributes.fetch("input.value")
    assert_equal JSON.generate("done"), root_span.attributes.fetch("output.value")
    assert_equal "agent_turn 1", turn_name
    refute_nil turn_context
    assert_equal "CHAIN", turn_span.attributes.fetch("openinference.span.kind")
    assert_equal "chat model-1", model_name
    refute_nil model_context
    assert_equal :client, model_span.kind
    assert_equal "LLM", model_span.attributes.fetch("openinference.span.kind")
    assert_equal "model-1", model_span.attributes.fetch("gen_ai.request.model")
    assert_equal "openrouter", model_span.attributes.fetch("gen_ai.provider.name")
    assert_equal 0.2, model_span.attributes.fetch("gen_ai.request.temperature")
    assert_equal 0.0125, model_span.attributes.fetch("gen_ai.response.time_to_first_chunk")
    assert_equal "response-1", model_span.attributes.fetch("gen_ai.response.id")
    assert_equal ["stop"], model_span.attributes.fetch("gen_ai.response.finish_reasons")
    assert_equal 14, model_span.attributes.fetch("gen_ai.usage.input_tokens")
    assert_equal 7, model_span.attributes.fetch("gen_ai.usage.output_tokens")
    assert_equal 3, model_span.attributes.fetch("gen_ai.usage.cache_read.input_tokens")
    assert_equal 1, model_span.attributes.fetch("gen_ai.usage.cache_creation.input_tokens")
    assert_equal 2, model_span.attributes.fetch("gen_ai.usage.reasoning.output_tokens")
    refute model_span.attributes.key?("gen_ai.usage.total_tokens")
    assert_equal 21, model_span.attributes.fetch("llm.token_count.total")
    assert_equal(
      [{"role" => "system", "parts" => [{"type" => "text", "content" => "instructions"}]}],
      JSON.parse(model_span.attributes.fetch("gen_ai.input.messages"))
    )
    definitions = JSON.parse(model_span.attributes.fetch("gen_ai.tool.definitions"))
    assert_equal "lookup", definitions.first.fetch("name")
    assert_equal "function", definitions.first.fetch("type")
    assert_equal "object", definitions.first.dig("parameters", "type")
    output = JSON.parse(model_span.attributes.fetch("gen_ai.output.messages")).first
    assert_equal "assistant", output.fetch("role")
    assert_equal "done", output.dig("parts", 0, "content")
    assert_equal "stop", output.fetch("finish_reason")
    assert root_span.finished?
    assert turn_span.finished?
    assert model_span.finished?
    assert_equal({trace_id: format("%032x", 123)}, trace_context)
  ensure
    tracing&.shutdown
  end

  def test_records_scrubbed_exception_details
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:model_start, {operation_id: "model", model_id: "model"})
    tracing.call(
      :model_stop,
      {
        operation_id: "model",
        outcome: :error,
        error_type: "LittleGhost::ProtocolError",
        diagnostic_exception: JSON.generate(
          type: "LittleGhost::ProtocolError",
          message: "request failed",
          stacktrace: "agent.rb:1"
        )
      }
    )

    span = tracer.started.first.last
    assert_equal "LittleGhost::ProtocolError", span.attributes.fetch("error.type")
    name, attributes = span.events.one? ? span.events.first : flunk("expected one exception event")
    assert_equal "gen_ai.client.operation.exception", name
    assert_equal "request failed", attributes.fetch("exception.message")
    assert_equal "agent.rb:1", attributes.fetch("exception.stacktrace")
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
  ensure
    tracing&.shutdown
  end

  def test_emits_captured_tool_content_and_custom_flat_attributes
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(
      :tool_start,
      {
        operation_id: "tool",
        tool_name: "lookup",
        diagnostic_input: JSON.generate(query: "safe"),
        "tag.tags": ["atlas", "main-agent"]
      }
    )
    tracing.call(:tool_stop, {operation_id: "tool", diagnostic_output: JSON.generate(result: "found")})

    span = tracer.started.first.last
    assert_equal "TOOL", span.attributes.fetch("openinference.span.kind")
    assert_equal "lookup", span.attributes.fetch("tool.name")
    assert_equal JSON.generate(query: "safe"), span.attributes.fetch("input.value")
    assert_equal JSON.generate(query: "safe"), span.attributes.fetch("gen_ai.tool.call.arguments")
    assert_equal "application/json", span.attributes.fetch("input.mime_type")
    assert_equal JSON.generate(result: "found"), span.attributes.fetch("output.value")
    assert_equal JSON.generate(result: "found"), span.attributes.fetch("gen_ai.tool.call.result")
    assert_equal ["atlas", "main-agent"], span.attributes.fetch("tag.tags")
  ensure
    tracing&.shutdown
  end

  def test_failed_tools_do_not_publish_a_semantic_result
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:tool_start, {operation_id: "tool", tool_name: "lookup"})
    tracing.call(
      :tool_stop,
      {
        operation_id: "tool",
        outcome: :error,
        error_type: "LittleGhost::ToolError",
        diagnostic_output: JSON.generate(error: "unavailable")
      }
    )

    span = tracer.started.first.last
    assert_equal JSON.generate(error: "unavailable"), span.attributes.fetch("output.value")
    refute span.attributes.key?("gen_ai.tool.call.result")
  ensure
    tracing&.shutdown
  end

  def test_redacts_content_and_credentials
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(
      :custom,
      {
        api_key: "secret",
        callback_token: "callback",
        prompt: "private",
        detail: "safe"
      }
    )

    attributes = tracer.instant.first.last
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.api_key")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.callback_token")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.prompt")
    assert_equal "safe", attributes.fetch("little_ghost.detail")
  end

  def test_subagent_spans_parent_the_delegated_agent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:subagent_start, {operation_id: "turn", kind: "explore"})
    tracing.call(:agent_start, {operation_id: "agent", parent_operation_id: "turn", agent_id: "ExploreAgent"})
    tracing.call(:subagent_stop, {operation_id: "turn", outcome: :cancelled})

    subagent_name, _context, subagent_span = tracer.started.fetch(0)
    agent_name, agent_context, = tracer.started.fetch(1)
    assert_equal "invoke_agent explore", subagent_name
    assert_equal "invoke_agent ExploreAgent", agent_name
    refute_nil agent_context
    assert subagent_span.finished?
  ensure
    tracing&.shutdown
  end
end
