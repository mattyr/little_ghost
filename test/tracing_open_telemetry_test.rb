# frozen_string_literal: true

require "test_helper"

class TracingOpenTelemetryTest < Minitest::Test
  Context = Struct.new(:trace_id) do
    def valid? = true
    def hex_trace_id = format("%032x", trace_id)
  end

  class Span
    attr_reader :attributes, :events, :context, :kind, :links
    attr_accessor :status

    def initialize(attributes = {}, kind: nil, links: [])
      @attributes = attributes.dup
      @events = []
      @context = Context.new(123)
      @kind = kind
      @links = links
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

    def start_span(name, with_parent: nil, kind: nil, attributes: {}, links: [])
      Span.new(attributes, kind:, links:).tap { |span| started << [name, with_parent, span] }
    end

    def start_root_span(name, kind: nil, attributes: {}, links: [])
      Span.new(attributes, kind:, links:).tap { |span| started << [name, :root, span] }
    end

    def in_span(name, attributes:)
      instant << [name, attributes]
      yield Span.new(attributes)
    end
  end

  def test_fuses_the_primary_agent_into_the_root_and_nests_turns_and_models
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(
      :run,
      {
        operation_id: "run",
        run_id: "run-1",
        session_id: "session-1",
        agent_id: "main",
        agent_name: "Support Agent",
        diagnostic_input: JSON.generate("hello")
      }
    )
    tracing.start(
      :agent,
      {
        operation_id: "agent",
        parent_operation_id: "run",
        agent_id: "main",
        agent_name: "Support Agent",
        available_tools: %w[lookup fetch],
        diagnostic_input: JSON.generate("hello")
      }
    )
    tracing.start(:agent_turn, {operation_id: "turn", parent_operation_id: "agent", turn: 1})
    tracing.start(
      :model,
      {
        operation_id: "model",
        parent_operation_id: "turn",
        model_id: "model-1",
        model_provider: :openrouter,
        model_settings: {temperature: 0.2},
        diagnostic_tool_definitions: JSON.generate(
          [{name: "lookup", description: "Look up a value", input_schema: {type: "object"}}]
        ),
        diagnostic_input: JSON.generate([{
          role: "system",
          content: [
            {type: "text", text: "instructions"},
            {type: "text", text: "<available_skills>skills</available_skills>"}
          ]
        }])
      }
    )
    tracing.finish(
      :model,
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
    tracing.finish(:agent_turn, {operation_id: "turn", outcome: :completed})
    tracing.finish(
      :agent,
      {operation_id: "agent", outcome: :completed, diagnostic_output: JSON.generate("done")}
    )
    trace_context = tracing.trace_context(operation_id: "run")
    tracing.finish(
      :run,
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
    assert_equal "invoke_agent Support Agent", root_name
    assert_nil root_context
    assert_equal :internal, root_span.kind
    assert_equal "session-1", root_span.attributes.fetch("gen_ai.conversation.id")
    refute root_span.attributes.key?("openinference.span.kind")
    assert_equal JSON.generate("hello"), root_span.attributes.fetch("input.value")
    assert_equal "application/json", root_span.attributes.fetch("input.mime_type")
    assert_equal JSON.generate("done"), root_span.attributes.fetch("output.value")
    assert_equal "application/json", root_span.attributes.fetch("output.mime_type")
    assert_equal "agent_turn 1", turn_name
    refute_nil turn_context
    refute turn_span.attributes.key?("openinference.span.kind")
    assert_equal "chat model-1", model_name
    refute_nil model_context
    assert_equal :client, model_span.kind
    refute model_span.attributes.key?("openinference.span.kind")
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
    refute model_span.attributes.key?("llm.token_count.total")
    refute model_span.attributes.key?("llm.input_messages")
    input_messages = JSON.parse(model_span.attributes.fetch("gen_ai.input.messages"))
    assert_equal model_span.attributes.fetch("gen_ai.input.messages"),
      model_span.attributes.fetch("input.value")
    assert_equal "application/json", model_span.attributes.fetch("input.mime_type")
    assert_equal ["system"], input_messages.map { |message| message.fetch("role") }
    assert_equal(
      ["instructions", "<available_skills>skills</available_skills>"],
      input_messages.first.fetch("parts").map { |part| part.fetch("content") }
    )
    definitions = JSON.parse(model_span.attributes.fetch("gen_ai.tool.definitions"))
    assert_equal "lookup", definitions.first.fetch("name")
    assert_equal "function", definitions.first.fetch("type")
    assert_equal "object", definitions.first.dig("parameters", "type")
    output = JSON.parse(model_span.attributes.fetch("gen_ai.output.messages")).first
    assert_equal model_span.attributes.fetch("gen_ai.output.messages"),
      model_span.attributes.fetch("output.value")
    assert_equal "application/json", model_span.attributes.fetch("output.mime_type")
    assert_equal "assistant", output.fetch("role")
    assert_equal "done", output.dig("parts", 0, "content")
    assert_equal "stop", output.fetch("finish_reason")
    assert root_span.finished?
    assert turn_span.finished?
    assert model_span.finished?
    assert_equal OpenTelemetry::Trace::Status::OK, root_span.status.code
    assert_equal OpenTelemetry::Trace::Status::OK, turn_span.status.code
    assert_equal OpenTelemetry::Trace::Status::OK, model_span.status.code
    assert_equal({trace_id: format("%032x", 123)}, trace_context)
  ensure
    tracing&.shutdown
  end

  def test_keeps_workflow_root_separate_from_its_child_agent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(
      :run,
      {
        operation_id: "run",
        entrypoint_kind: :workflow,
        workflow_name: "MainResponseWorkflow",
        session_id: "session-1"
      }
    )
    tracing.start(
      :agent,
      {
        operation_id: "agent",
        parent_operation_id: "run",
        agent_id: "main",
        agent_name: "Support Agent"
      }
    )
    tracing.finish(:agent, {operation_id: "agent", outcome: :completed})
    tracing.finish(:run, {operation_id: "run", outcome: :completed})

    workflow_name, workflow_context, workflow_span = tracer.started.fetch(0)
    agent_name, agent_context, agent_span = tracer.started.fetch(1)
    assert_equal "invoke_workflow MainResponseWorkflow", workflow_name
    assert_nil workflow_context
    assert_equal "invoke_workflow", workflow_span.attributes.fetch("gen_ai.operation.name")
    assert_equal "MainResponseWorkflow", workflow_span.attributes.fetch("gen_ai.workflow.name")
    refute workflow_span.attributes.key?("gen_ai.agent.id")
    assert_equal "invoke_agent Support Agent", agent_name
    refute_nil agent_context
    assert_equal "invoke_agent", agent_span.attributes.fetch("gen_ai.operation.name")
    assert_equal "main", agent_span.attributes.fetch("gen_ai.agent.id")
    assert workflow_span.finished?
    assert agent_span.finished?
  ensure
    tracing&.shutdown
  end

  def test_names_swarm_root_separately_from_its_member_agent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(
      :run,
      {
        operation_id: "run",
        entrypoint_kind: :swarm,
        assembly_id: "problem_solver",
        assembly_kind: :swarm
      }
    )
    tracing.finish(:run, {operation_id: "run", outcome: :completed})

    name, _context, span = tracer.started.fetch(0)
    assert_equal "invoke_swarm problem_solver", name
    assert_equal "invoke_swarm", span.attributes.fetch("gen_ai.operation.name")
    assert_equal "problem_solver", span.attributes.fetch("little_ghost.assembly.id")
    assert_equal "swarm", span.attributes.fetch("little_ghost.assembly.kind")
  ensure
    tracing&.shutdown
  end

  def test_records_scrubbed_exception_details
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:model, {operation_id: "model", model_id: "model"})
    tracing.finish(
      :model,
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
    refute attributes.key?("exception.escaped")
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert_equal "LittleGhost::ProtocolError: request failed", span.status.description
  ensure
    tracing&.shutdown
  end

  def test_omits_malformed_or_truncated_model_messages
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(
      :model,
      {
        operation_id: "model",
        model_id: "model",
        diagnostic_input: JSON.generate(truncated: true, preview: "[{\"role\":\"system\"")
      }
    )
    tracing.finish(:model, {operation_id: "model"})

    span = tracer.started.first.last
    refute span.attributes.key?("gen_ai.input.messages")
  ensure
    tracing&.shutdown
  end

  def test_preserves_large_canonical_model_histories
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    content = "context " * 20_000

    tracing.start(
      :model,
      {
        operation_id: "model",
        model_id: "model",
        diagnostic_input: JSON.generate([
          {role: "system", content: [{type: "text", text: content}]},
          {role: "user", content: [{type: "text", text: "current request"}]}
        ])
      }
    )
    tracing.finish(:model, {operation_id: "model"})

    messages = JSON.parse(tracer.started.first.last.attributes.fetch("gen_ai.input.messages"))
    assert_equal %w[system user], messages.map { |message| message.fetch("role") }
    assert_equal content, messages.first.dig("parts", 0, "content")
  ensure
    tracing&.shutdown
  end

  def test_emits_canonical_captured_tool_content_and_custom_flat_attributes
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(
      :tool,
      {
        operation_id: "tool",
        tool_name: "lookup",
        tool_type: "function",
        diagnostic_input: JSON.generate(query: "safe"),
        diagnostic_tool_definitions: JSON.generate([
          {name: "lookup", description: "Look up a value", input_schema: {type: "object"}}
        ]),
        "tag.tags": ["customer-support", "primary-agent"]
      }
    )
    tracing.finish(:tool, {operation_id: "tool", diagnostic_output: JSON.generate(result: "found")})

    span = tracer.started.first.last
    refute span.attributes.key?("openinference.span.kind")
    refute span.attributes.key?("tool.name")
    assert_equal JSON.generate(query: "safe"), span.attributes.fetch("input.value")
    assert_equal "Look up a value", span.attributes.fetch("gen_ai.tool.description")
    assert_equal "function", span.attributes.fetch("gen_ai.tool.type")
    refute span.attributes.key?("little_ghost.tool_input_schema")
    assert_equal JSON.generate(query: "safe"), span.attributes.fetch("gen_ai.tool.call.arguments")
    assert_equal "application/json", span.attributes.fetch("input.mime_type")
    assert_equal JSON.generate(result: "found"), span.attributes.fetch("output.value")
    assert_equal "application/json", span.attributes.fetch("output.mime_type")
    assert_equal JSON.generate(result: "found"), span.attributes.fetch("gen_ai.tool.call.result")
    assert_equal ["customer-support", "primary-agent"], span.attributes.fetch("tag.tags")
    assert_equal OpenTelemetry::Trace::Status::OK, span.status.code
  ensure
    tracing&.shutdown
  end

  def test_failed_tools_do_not_publish_a_semantic_result
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:tool, {operation_id: "tool", tool_name: "lookup"})
    tracing.finish(
      :tool,
      {
        operation_id: "tool",
        outcome: :error,
        error_type: "LittleGhost::ToolError",
        diagnostic_output: JSON.generate(error: "unavailable")
      }
    )

    span = tracer.started.first.last
    refute span.attributes.key?("output.value")
    refute span.attributes.key?("gen_ai.tool.call.result")
    assert_equal OpenTelemetry::Trace::Status::ERROR, span.status.code
    assert_equal "LittleGhost::ToolError", span.events.first.last.fetch("exception.type")
  ensure
    tracing&.shutdown
  end

  def test_every_model_span_exposes_common_input_and_output_including_tool_only_responses
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    first_input = JSON.generate([
      {role: "system", content: [{type: "text", text: "delegate carefully"}]},
      {role: "user", content: [{type: "text", text: "investigate"}]}
    ])
    tool_output = JSON.generate(
      role: "assistant",
      content: [{
        type: "tool_use",
        id: "call-1",
        name: "spawn_subagent",
        input: {kind: "evidence", task: "check logs", mode: "async"}
      }]
    )
    second_input = JSON.generate([
      {role: "system", content: [{type: "text", text: "delegate carefully"}]},
      {role: "assistant", content: JSON.parse(tool_output).fetch("content")},
      {
        role: "tool",
        content: [{
          type: "tool_result",
          tool_use_id: "call-1",
          content: {status: "working", subagent_id: "evidence-1"}
        }]
      }
    ])
    final_output = JSON.generate(
      role: "assistant",
      content: [{type: "text", text: "The investigation is complete."}]
    )

    tracing.start(:model, operation_id: "model-1", model_id: "model", diagnostic_input: first_input)
    tracing.finish(
      :model,
      operation_id: "model-1",
      stop_reason: :tool_use,
      diagnostic_output: tool_output
    )
    tracing.start(:model, operation_id: "model-2", model_id: "model", diagnostic_input: second_input)
    tracing.finish(
      :model,
      operation_id: "model-2",
      stop_reason: :end_turn,
      diagnostic_output: final_output
    )

    spans = tracer.started.map(&:last)
    assert_equal 2, spans.length
    spans.each do |span|
      assert_equal "application/json", span.attributes.fetch("input.mime_type")
      assert_equal "application/json", span.attributes.fetch("output.mime_type")
      assert span.attributes.key?("gen_ai.input.messages")
      assert span.attributes.key?("gen_ai.output.messages")
      assert_equal span.attributes.fetch("gen_ai.input.messages"), span.attributes.fetch("input.value")
      assert_equal span.attributes.fetch("gen_ai.output.messages"), span.attributes.fetch("output.value")
    end
    tool_call = JSON.parse(spans.first.attributes.fetch("gen_ai.output.messages"))
      .first.fetch("parts").first
    assert_equal "tool_call", tool_call.fetch("type")
    assert_equal "spawn_subagent", tool_call.fetch("name")
  ensure
    tracing&.shutdown
  end

  def test_redacts_content_and_credentials
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.emit(
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

  def test_attaches_custom_events_to_their_operation_span
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:tool, {operation_id: "tool", tool_name: "lookup"})
    tracing.emit(:tool_loop, {operation_id: "tool", action: :warn, tool_name: "lookup", count: 3})

    span = tracer.started.first.last
    name, attributes = span.events.one? ? span.events.first : flunk("expected one tool-loop event")
    assert_equal "little_ghost.tool_loop", name
    assert_equal "warn", attributes.fetch("little_ghost.action")
    assert_empty tracer.instant
  ensure
    tracing&.shutdown
  end

  def test_attaches_custom_events_to_an_active_operation_after_its_parent_finishes
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:model, {operation_id: "model", model_id: "model"})
    tracing.start(
      :tool,
      {operation_id: "tool", parent_operation_id: "model", tool_name: "lookup"}
    )
    tracing.finish(:model, {operation_id: "model"})
    tracing.emit(
      :tool_loop,
      {
        operation_id: "tool",
        parent_operation_id: "model",
        action: :final_warning,
        tool_name: "lookup",
        count: 4
      }
    )

    tool_span = tracer.started.fetch(1).last
    name, attributes = tool_span.events.one? ? tool_span.events.first : flunk("expected one tool-loop event")
    assert_equal "little_ghost.tool_loop", name
    assert_equal "final_warning", attributes.fetch("little_ghost.action")
    assert_empty tracer.instant
  ensure
    tracing&.shutdown
  end

  def test_prefers_the_active_operation_span_over_its_active_parent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:model, {operation_id: "model", model_id: "model"})
    tracing.start(
      :tool,
      {operation_id: "tool", parent_operation_id: "model", tool_name: "lookup"}
    )
    tracing.emit(
      :tool_loop,
      {
        operation_id: "tool",
        parent_operation_id: "model",
        action: :warn,
        tool_name: "lookup",
        count: 3
      }
    )

    model_span = tracer.started.fetch(0).last
    tool_span = tracer.started.fetch(1).last
    assert_empty model_span.events
    name, attributes = tool_span.events.one? ? tool_span.events.first : flunk("expected one tool-loop event")
    assert_equal "little_ghost.tool_loop", name
    assert_equal "warn", attributes.fetch("little_ghost.action")
    assert_empty tracer.instant
  ensure
    tracing&.shutdown
  end

  def test_attaches_safe_retry_details_to_the_model_span
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:model, {operation_id: "model", model_id: "model"})
    tracing.emit(
      :model_retry,
      {
        parent_operation_id: "model",
        error_class: "LittleGhost::Providers::HTTPError",
        error_code: "server_error",
        http_status: 503,
        partial_text: true
      }
    )

    span = tracer.started.first.last
    assert_equal 1, span.events.length
    name, attributes = span.events.first
    assert_equal "little_ghost.model_retry", name
    assert_equal "LittleGhost::Providers::HTTPError", attributes.fetch("error.type")
    assert_equal "server_error", attributes.fetch("little_ghost.error_code")
    assert_equal 503, attributes.fetch("little_ghost.http_status")
    assert_equal true, attributes.fetch("little_ghost.partial_text")
    refute attributes.key?("exception.message")
  ensure
    tracing&.shutdown
  end

  def test_attaches_delivered_interrupt_to_its_started_model_span
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:model, {operation_id: "model", model_id: "model"})
    tracing.emit(
      :agent_interrupt_delivered,
      {
        parent_operation_id: "model",
        interruption_id: "interrupt",
        event_kind: :interrupt
      }
    )

    span = tracer.started.first.last
    assert_equal 1, span.events.length
    name, attributes = span.events.first
    assert_equal "little_ghost.agent_interrupt_delivered", name
    assert_equal "interrupt", attributes.fetch("little_ghost.interruption_id")
    assert_empty tracer.instant
  ensure
    tracing&.shutdown
  end

  def test_subagent_spans_parent_the_delegated_agent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)

    tracing.start(:agent, {
      operation_id: "caller",
      agent_id: "InvestigatorAgent",
      diagnostic_input: JSON.generate("investigate")
    })
    tracing.start(:subagent, {
      operation_id: "turn",
      parent_operation_id: "caller",
      subagent_id: "evidence-1",
      kind: "explore"
    })
    tracing.finish(:agent, {
      operation_id: "caller",
      diagnostic_output: JSON.generate("delegation queued")
    })
    tracing.start(:agent, {
      operation_id: "agent",
      parent_operation_id: "turn",
      agent_id: "ExploreAgent",
      diagnostic_input: JSON.generate("check evidence")
    })
    tracing.finish(:agent, {
      operation_id: "agent",
      diagnostic_output: JSON.generate("evidence found")
    })
    tracing.finish(:subagent, {operation_id: "turn", outcome: :cancelled})

    caller_name, _caller_context, caller_span = tracer.started.fetch(0)
    subagent_name, subagent_context, subagent_span = tracer.started.fetch(1)
    agent_name, agent_context, agent_span = tracer.started.fetch(2)
    assert_equal "invoke_agent InvestigatorAgent", caller_name
    assert_equal "invoke_agent evidence-1", subagent_name
    assert_equal "invoke_agent ExploreAgent", agent_name
    refute_nil subagent_context
    refute_nil agent_context
    assert subagent_span.finished?
    assert_equal JSON.generate("check evidence"), agent_span.attributes.fetch("input.value")
    assert_equal JSON.generate("evidence found"), agent_span.attributes.fetch("output.value")
    assert_equal JSON.generate("delegation queued"), caller_span.attributes.fetch("output.value")
    assert_equal JSON.generate("investigate"), caller_span.attributes.fetch("input.value")
  ensure
    tracing&.shutdown
  end

  def test_run_nests_async_subagent_work_under_the_caller_across_threads
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      subscribers: [tracing]
    )
    agent_class = Class.new(LittleGhost::Agent) { agent_id "main" }
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "hello"),
      agent_class:,
      runtime: TestRuntime.new
    )
    caller = LittleGhost::Instrumentation.start(
      :agent,
      operation_id: "caller",
      agent_id: "main",
      agent_name: "Support Agent"
    )
    event = {
      subagent_id: "/root/research",
      conversation_id: "conversation",
      kind: "deep_research",
      turn: 1,
      operation_id: "turn",
      parent_operation_id: "caller"
    }

    run.publish(:subagent, event: event.merge(event: "spawned"))
    assert_same caller, LittleGhost::Instrumentation.current
    caller.finish(outcome: :completed)

    Thread.new do
      run.publish(:subagent, event: event.merge(event: "turn_started"))
      delegated = LittleGhost::Instrumentation.start(
        :agent,
        parent: "turn",
        operation_id: "delegated",
        agent_id: "deep-research",
        agent_name: "Research Agent"
      )
      delegated.finish(outcome: :completed)
      run.publish(:subagent, event: event.merge(event: "turn_finished"))
    end.join

    caller_name, _caller_parent, caller_span = tracer.started.fetch(0)
    subagent_name, subagent_parent, subagent_span = tracer.started.fetch(1)
    delegated_name, delegated_parent, delegated_span = tracer.started.fetch(2)
    assert_equal "invoke_agent Support Agent", caller_name
    assert_equal "invoke_agent /root/research", subagent_name
    assert_equal "invoke_agent Research Agent", delegated_name
    assert_equal caller_span.context, OpenTelemetry::Trace.current_span(subagent_parent).context
    assert_equal subagent_span.context, OpenTelemetry::Trace.current_span(delegated_parent).context
    assert_equal %w[
      little_ghost.subagent_spawned
      little_ghost.subagent_turn_started
      little_ghost.subagent_finished
    ], subagent_span.events.map(&:first)
    assert caller_span.finished?
    assert subagent_span.finished?
    assert delegated_span.finished?
    assert_empty tracer.instant
    refute instrumentation.active?
  ensure
    tracing&.shutdown
  end

  def test_trace_links_start_a_new_root_trace
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    parent = OpenTelemetry::Trace::SpanContext.new(
      trace_id: ["1".rjust(32, "0")].pack("H*"),
      span_id: ["2".rjust(16, "0")].pack("H*"),
      trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
    )
    carrier = {
      "traceparent" => "00-#{parent.hex_trace_id}-#{parent.hex_span_id}-01"
    }

    tracing.start(:run, operation_id: "run", agent_id: "engineering", trace_links: [carrier])

    _name, parent_context, span = tracer.started.fetch(0)
    assert_equal :root, parent_context
    assert_equal 1, span.links.length
    assert_equal parent.hex_trace_id, span.links.first.span_context.hex_trace_id
    assert_equal parent.hex_span_id, span.links.first.span_context.hex_span_id
    assert span.links.first.span_context.remote?
  ensure
    tracing&.shutdown
  end

  def test_with_span_uses_an_active_operation_as_parent
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    tracing.start(:run, operation_id: "run", agent_id: "main")

    tracing.with_span(
      "BedrockAgentCore/list_events",
      attributes: {"rpc.method" => "list_events"},
      parent_operation_id: "run"
    ) { |span| span.set_attribute("test", true) }

    _root_name, _root_parent, root_span = tracer.started.fetch(0)
    child_name, child_parent, child_span = tracer.started.fetch(1)
    assert_equal "BedrockAgentCore/list_events", child_name
    assert_equal root_span.context, OpenTelemetry::Trace.current_span(child_parent).context
    assert_equal true, child_span.attributes.fetch("test")
    assert child_span.finished?
  ensure
    tracing&.shutdown
  end

  def test_explicit_trace_context_parents_a_span_after_the_local_parent_is_gone
    tracer = Tracer.new
    tracing = LittleGhost::Tracing::OpenTelemetry.new(tracer:)
    parent = OpenTelemetry::Trace::SpanContext.new(
      trace_id: ["1".rjust(32, "0")].pack("H*"),
      span_id: ["2".rjust(16, "0")].pack("H*"),
      trace_flags: OpenTelemetry::Trace::TraceFlags::SAMPLED
    )
    carrier = {
      "traceparent" => "00-#{parent.hex_trace_id}-#{parent.hex_span_id}-01"
    }

    tracing.start(
      :tool,
      operation_id: "nested-tool",
      parent_operation_id: "finished-parent",
      trace_context: carrier,
      tool_name: "lookup"
    )

    _name, parent_context, = tracer.started.fetch(0)
    remote_parent = OpenTelemetry::Trace.current_span(parent_context).context
    assert_equal parent.hex_trace_id, remote_parent.hex_trace_id
    assert_equal parent.hex_span_id, remote_parent.hex_span_id
  ensure
    tracing&.shutdown
  end
end
