# frozen_string_literal: true

require "test_helper"

class TracingOpenTelemetryTest < Minitest::Test
  Context = Struct.new(:trace_id) do
    def valid? = true
    def hex_trace_id = format("%032x", trace_id)
  end

  class Span
    attr_reader :attributes, :events, :context
    attr_accessor :status

    def initialize(attributes = {})
      @attributes = attributes.dup
      @events = []
      @context = Context.new(123)
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

    def start_span(name, with_parent: nil, attributes: {})
      Span.new(attributes).tap { |span| started << [name, with_parent, span] }
    end

    def in_span(name, attributes:)
      instant << [name, attributes]
      yield Span.new(attributes)
    end
  end

  def test_builds_nested_gen_ai_spans
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:run_start, {operation_id: "run", run_id: "run-1", session_id: "session-1"})
    tracing.call(:model_retry, {operation_id: "run", attempt: 2, error_class: "ProviderError"})
    tracing.call(
      :agent_start,
      {operation_id: "agent", parent_operation_id: "run", agent_id: "agent-1", available_tools: %w[lookup fetch]}
    )
    tracing.call(
      :model_start,
      {
        operation_id: "model",
        parent_operation_id: "agent",
        model_id: "model-1",
        model_provider: :openrouter
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
        time_to_first_token: 0.0125
      }
    )

    run_name, _root_context, run_span = tracer.started.fetch(0)
    _agent_name, _agent_parent, agent_span = tracer.started.fetch(1)
    model_name, parent_context, model_span = tracer.started.fetch(2)
    assert_equal "invoke_agent", run_name
    assert_equal "session-1", run_span.attributes.fetch("session.id")
    assert_equal "little_ghost.model_retry", run_span.events.first.first
    assert_equal "ProviderError", run_span.events.first.last.fetch("little_ghost.error_class")
    assert_equal "chat model-1", model_name
    refute_nil parent_context
    assert_equal "chat", model_span.attributes.fetch("gen_ai.operation.name")
    assert_equal "LLM", model_span.attributes.fetch("openinference.span.kind")
    assert_equal "model-1", model_span.attributes.fetch("gen_ai.request.model")
    assert_equal "model-1", model_span.attributes.fetch("llm.model_name")
    assert_equal "openrouter", model_span.attributes.fetch("gen_ai.provider.name")
    assert_equal "openrouter", model_span.attributes.fetch("llm.provider")
    assert_equal %w[lookup fetch], agent_span.attributes.fetch("gen_ai.agent.tools")
    assert_equal "lookup", agent_span.attributes.fetch("llm.tools.0.tool.name")
    assert_equal "fetch", agent_span.attributes.fetch("llm.tools.1.tool.name")
    assert_equal 0.0125, model_span.attributes.fetch("gen_ai.server.time_to_first_token")
    assert_equal 14, model_span.attributes.fetch("gen_ai.usage.input_tokens")
    assert_equal 7, model_span.attributes.fetch("gen_ai.usage.output_tokens")
    assert_equal 21, model_span.attributes.fetch("gen_ai.usage.total_tokens")
    assert_equal 3, model_span.attributes.fetch("gen_ai.usage.cache_read_input_tokens")
    assert_equal 1, model_span.attributes.fetch("gen_ai.usage.cache_write_input_tokens")
    assert_equal 2, model_span.attributes.fetch("gen_ai.usage.reasoning_tokens")
    assert_equal 14, model_span.attributes.fetch("llm.token_count.prompt")
    assert_equal 7, model_span.attributes.fetch("llm.token_count.completion")
    assert_equal 21, model_span.attributes.fetch("llm.token_count.total")
    assert_equal 3, model_span.attributes.fetch("llm.token_count.prompt_details.cache_read")
    assert_equal 1, model_span.attributes.fetch("llm.token_count.prompt_details.cache_write")
    assert_equal 2, model_span.attributes.fetch("llm.token_count.completion_details.reasoning")
    assert_equal 21, model_span.attributes.fetch("little_ghost.total_tokens")
    assert_equal 3, model_span.attributes.fetch("little_ghost.cache_read_tokens")
    assert_equal 1, model_span.attributes.fetch("little_ghost.cache_write_tokens")
    assert_equal 2, model_span.attributes.fetch("little_ghost.reasoning_tokens")
    assert model_span.finished?
    assert_equal({trace_id: format("%032x", 123)}, tracing.trace_context(operation_id: "run"))
    refute run_span.finished?
  ensure
    tracing&.shutdown
  end

  def test_emits_captured_content_and_custom_semantic_attributes
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
    tracing.call(
      :tool_stop,
      {operation_id: "tool", diagnostic_output: JSON.generate(result: "found")}
    )

    _name, _parent, span = tracer.started.fetch(0)
    assert_equal "TOOL", span.attributes.fetch("openinference.span.kind")
    assert_equal "lookup", span.attributes.fetch("tool.name")
    assert_equal JSON.generate(query: "safe"), span.attributes.fetch("input.value")
    assert_equal "application/json", span.attributes.fetch("input.mime_type")
    assert_equal JSON.generate(result: "found"), span.attributes.fetch("output.value")
    assert_equal ["atlas", "main-agent"], span.attributes.fetch("tag.tags")
  ensure
    tracing&.shutdown
  end

  def test_redacts_content_and_credentials
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(
      :custom,
      {
        :api_key => "secret",
        :callback_token => "callback",
        "callbackToken" => "camel-case",
        :token => "generic",
        :prompt => "private",
        "inputText" => "private camel-case content",
        :detail => "safe"
      }
    )

    attributes = tracer.instant.first.last
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.api_key")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.callback_token")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.callbackToken")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.token")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.prompt")
    assert_equal "[REDACTED]", attributes.fetch("little_ghost.inputText")
    assert_equal "safe", attributes.fetch("little_ghost.detail")
  end

  def test_subagent_spans_parent_the_delegated_agent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:subagent_start, {operation_id: "turn", parent_operation_id: "run", kind: "explore"})
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

  def test_span_names_are_bounded
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.call(:tool_start, {operation_id: "tool", tool_name: "x" * 2_000})

    name, = tracer.started.fetch(0)
    assert_equal 1_037, name.length
  ensure
    tracing&.shutdown
  end
end
