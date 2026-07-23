# frozen_string_literal: true

require "test_helper"
require "little_ghost/providers/openai"

class OpenAICompatibleTest < Minitest::Test
  class FakeTransport
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def stream(**request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response.each { |chunk| yield chunk }
    end
  end

  def test_responses_stream_normalizes_text_reasoning_tools_and_usage
    events = [
      {type: "response.created", response: {id: "resp_1", model: "gpt-test"}},
      {type: "response.reasoning_summary_text.delta", delta: "Think"},
      {type: "response.output_text.delta", delta: "Hello"},
      {type: "response.output_item.added", output_index: 1, item: {type: "function_call", call_id: "call_1", name: "weather"}},
      {type: "response.function_call_arguments.delta", output_index: 1, delta: "{\"city\":"},
      {type: "response.function_call_arguments.delta", output_index: 1, delta: "\"Paris\"}"},
      {type: "response.output_item.done", output_index: 1, item: {type: "function_call", call_id: "call_1", name: "weather", arguments: "{\"city\":\"Paris\"}"}},
      {type: "response.completed", response: {id: "resp_1", model: "gpt-test", status: "completed", usage: {input_tokens: 12, output_tokens: 4, input_tokens_details: {cached_tokens: 5}, output_tokens_details: {reasoning_tokens: 2}}}}
    ]
    transport = FakeTransport.new(fragmented_sse(events))
    provider = provider(transport:)

    result = provider.stream(request).to_a

    assert_equal %i[message_start reasoning_delta text_delta tool_call_start tool_call_delta tool_call_delta tool_call_stop usage message_stop], result.map(&:type)
    assert_equal({"city" => "Paris"}, result[-3].data[:tool_use].input)
    response = result.last.data.fetch(:response)
    assert_equal :tool_use, response.stop_reason
    assert_equal "Hello", response.message.text
    assert_equal 5, response.usage.cache_read_tokens
    assert_equal 2, response.usage.reasoning_tokens
    assert_equal 2, response.usage.output_tokens
    assert_equal 16, response.usage.total_tokens
    assert_equal ["Think"], response.message.content.grep(LittleGhost::Content::Reasoning).map(&:text)
  end

  def test_responses_request_serializes_messages_tools_and_settings
    transport = FakeTransport.new(["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    tool = {name: "lookup", description: "Look up", input_schema: {type: "object"}}
    messages = [
      {role: :system, content: "Be concise"},
      {role: :assistant, content: [LittleGhost::Content::ToolUse.new(id: "c1", name: "lookup", input: {"q" => "x"})]},
      {role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "c1", content: "found", status: :success)]}
    ]
    provider(transport:).stream(request(messages:, tools: [tool], settings: {temperature: 0.2, ignored: true})).to_a
    body = JSON.parse(transport.requests.fetch(0).fetch(:body))

    assert_equal "gpt-test", body["model"]
    assert_equal 0.2, body["temperature"]
    refute body.key?("ignored")
    assert_equal "function_call", body["input"][1]["type"]
    assert_equal "function_call_output", body["input"][2]["type"]
    assert_equal "lookup", body.dig("tools", 0, "name")
  end

  def test_responses_replays_assistant_text_as_input_text
    transport = FakeTransport.new(["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    messages = [{role: :assistant, content: "Previous answer"}, {role: :user, content: "Continue"}]

    provider(transport:).stream(request(messages:)).to_a

    body = JSON.parse(transport.requests.fetch(0).fetch(:body))
    assert_equal "input_text", body.dig("input", 0, "content", 0, "type")
  end

  def test_does_not_replay_private_reasoning_as_visible_input
    reasoning = LittleGhost::Content::Reasoning.new(text: "private chain of thought")
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup", input: {"id" => 1})
    messages = [
      {role: :assistant, content: [reasoning, tool_use]},
      {role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "found", status: :success)]}
    ]

    responses_transport = FakeTransport.new(["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    provider(transport: responses_transport).stream(request(messages:)).to_a
    responses_body = JSON.parse(responses_transport.requests.fetch(0).fetch(:body))

    chat_transport = FakeTransport.new(sse([chat_chunk(id: "chat-1", delta: {}, finish_reason: "stop")]))
    provider(transport: chat_transport, api: :chat_completions).stream(request(messages:)).to_a
    chat_body = JSON.parse(chat_transport.requests.fetch(0).fetch(:body))

    refute_includes JSON.generate(responses_body), reasoning.text
    refute_includes JSON.generate(chat_body), reasoning.text
    assert_equal "function_call", responses_body.dig("input", 0, "type")
    assert_equal "function", chat_body.dig("messages", 0, "tool_calls", 0, "type")
  end

  def test_chat_completions_combines_parallel_tool_fragments
    chunks = [
      chat_chunk(id: "chat_1", delta: {content: "Hi ", reasoning_content: "why"}),
      chat_chunk(id: "chat_1", delta: {tool_calls: [{index: 0, id: "a", function: {name: "first", arguments: "{\"x\":"}}, {index: 1, id: "b", function: {name: "second", arguments: "{}"}}]}),
      chat_chunk(id: "chat_1", delta: {tool_calls: [{index: 0, function: {arguments: "1}"}}]}, finish_reason: "tool_calls"),
      {id: "chat_1", model: "gpt-test", choices: [], usage: {prompt_tokens: 8, completion_tokens: 3, prompt_tokens_details: {cached_tokens: 2}, completion_tokens_details: {reasoning_tokens: 1}}}
    ]
    transport = FakeTransport.new(sse(chunks))
    result = provider(transport:, api: :chat_completions).stream(request).to_a

    assert_equal 2, result.count { |event| event.type == :tool_call_stop }
    response = result.last.data[:response]
    assert_equal :tool_use, response.stop_reason
    assert_equal [{"x" => 1}, {}], response.message.content.grep(LittleGhost::Content::ToolUse).map(&:input)
    assert_equal 2, response.usage.cache_read_tokens
    assert_equal 1, response.usage.reasoning_tokens
    assert_equal 2, response.usage.output_tokens
  end

  def test_chat_completions_preserves_ordered_reasoning_details
    chunks = [
      chat_chunk(
        id: "chat_1",
        delta: {
          reasoning: "Think ",
          reasoning_details: [
            {
              type: "reasoning.text", index: 0, format: "openai-responses-v1",
              text: "Think ", signature: "signed"
            }
          ]
        }
      ),
      chat_chunk(
        id: "chat_1",
        delta: {
          reasoning: "carefully",
          reasoning_details: [
            {type: "reasoning.text", index: 0, format: nil, text: "carefully", signature: nil},
            {type: "reasoning.encrypted", index: 1, data: "opaque"}
          ]
        },
        finish_reason: "stop"
      )
    ]

    events = provider(
      transport: FakeTransport.new(sse(chunks)),
      api: :chat_completions
    ).stream(request).to_a
    reasoning = events.last.data.fetch(:response).message.content.grep(LittleGhost::Content::Reasoning).fetch(0)

    assert_equal "Think carefully", reasoning.text
    assert_equal [
      {
        "type" => "reasoning.text", "index" => 0, "format" => "openai-responses-v1",
        "text" => "Think carefully", "signature" => "signed"
      },
      {"type" => "reasoning.encrypted", "index" => 1, "data" => "opaque"}
    ], reasoning.details
    assert reasoning.details.frozen?
  end

  def test_chat_completions_emits_one_start_when_identity_is_repeated
    chunks = [
      chat_chunk(id: "chat_1", delta: {tool_calls: [{index: 0, id: "a", function: {name: "first", arguments: "{"}}]}),
      chat_chunk(id: "chat_1", delta: {tool_calls: [{index: 0, id: "a", function: {name: "first", arguments: "}"}}]}, finish_reason: "tool_calls")
    ]

    events = provider(transport: FakeTransport.new(sse(chunks)), api: :chat_completions).stream(request).to_a

    assert_equal 1, events.count { |event| event.type == :tool_call_start }
  end

  def test_chat_completions_accepts_clean_eof_after_a_finish_reason
    chunks = [
      "data: #{JSON.generate(chat_chunk(id: "chat_1", delta: {content: "done"}, finish_reason: "stop"))}\n\n",
      "data: #{JSON.generate({id: "chat_1", model: "gpt-test", choices: [], usage: {prompt_tokens: 4, completion_tokens: 1}})}\n\n"
    ]

    events = provider(transport: FakeTransport.new(chunks), api: :chat_completions).stream(request).to_a

    assert_equal :message_stop, events.last.type
    assert_equal "done", events.last.data.fetch(:response).message.text
    assert_equal 5, events.last.data.fetch(:response).usage.total_tokens
  end

  def test_chat_completions_rejects_clean_eof_without_a_finish_reason
    chunks = ["data: #{JSON.generate(chat_chunk(id: "chat_1", delta: {content: "partial"}))}\n\n"]

    error = assert_raises(LittleGhost::ProtocolError) do
      provider(transport: FakeTransport.new(chunks), api: :chat_completions).stream(request).to_a
    end

    assert_includes error.message, "terminal event"
  end

  def test_chat_completions_accepts_a_tool_call_at_clean_eof
    chunks = [
      chat_chunk(
        id: "chat_1",
        delta: {tool_calls: [{index: 0, id: "call_1", function: {name: "lookup", arguments: "{\"id\":1}"}}]},
        finish_reason: "tool_calls"
      )
    ].map { |event| "data: #{JSON.generate(event)}\n\n" }

    events = provider(transport: FakeTransport.new(chunks), api: :chat_completions).stream(request).to_a
    response = events.last.data.fetch(:response)

    assert_equal 1, events.count { |event| event.type == :tool_call_stop }
    assert_equal :tool_use, response.stop_reason
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
  end

  def test_chat_completions_rejects_malformed_tool_arguments_at_terminal_clean_eof
    event = chat_chunk(
      id: "chat_1",
      delta: {tool_calls: [{index: 0, id: "call_1", function: {name: "lookup", arguments: "{"}}]},
      finish_reason: "tool_calls"
    )
    chunks = ["data: #{JSON.generate(event)}\n\n"]

    assert_raises(LittleGhost::MalformedToolCallError) do
      provider(transport: FakeTransport.new(chunks), api: :chat_completions).stream(request).to_a
    end
  end

  def test_retries_retryable_failure_before_emitting_events
    failure = LittleGhost::Providers::HTTPError.new("busy", status: 429)
    transport = FakeTransport.new(failure, ["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    delays = []
    retries = []

    result = provider(
      transport:,
      max_retries: 1,
      sleeper: ->(delay) { delays << delay },
      on_retry: ->(*arguments) { retries << arguments }
    ).stream(request).to_a

    assert_equal 2, transport.requests.length
    assert_equal [1], delays
    assert_equal [[1, failure, 1]], retries
    assert_equal :message_stop, result.last.type
  end

  def test_retries_a_transient_stream_failure_after_partial_output
    completed = sse([
      {type: "response.created", response: {id: "retry", model: "gpt-test"}},
      {type: "response.output_text.delta", delta: "complete"},
      {type: "response.completed", response: {id: "retry", model: "gpt-test", status: "completed"}}
    ])
    transport = Class.new do
      attr_reader :calls

      def initialize(completed)
        @calls = 0
        @completed = completed
      end

      def stream(**)
        @calls += 1
        if calls == 1
          yield "data: {\"type\":\"response.created\",\"response\":{\"id\":\"first\",\"model\":\"gpt-test\"}}\n\n"
          yield "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
          raise LittleGhost::Providers::HTTPError.new("lost", status: 503)
        end

        @completed.each { |chunk| yield chunk }
      end
    end.new(completed)
    delivered = []
    retries = []

    provider(
      transport:, max_retries: 1, sleeper: ->(*) {},
      on_retry: ->(*arguments) { retries << arguments }
    ).stream(request) { |event| delivered << event }

    assert_equal 2, transport.calls
    assert_equal 1, retries.length
    assert_equal %i[message_start text_delta model_retry message_start text_delta message_stop], delivered.map(&:type)
    assert_equal "complete", delivered.last.data.fetch(:response).message.text
  end

  def test_retries_after_a_partial_tool_call_and_returns_only_the_successful_attempt
    first = [
      {type: "response.created", response: {id: "first", model: "gpt-test"}},
      {type: "response.output_item.added", output_index: 0, item: {type: "function_call", call_id: "stale", name: "stale"}},
      {type: "response.function_call_arguments.delta", output_index: 0, delta: "{}"},
      {type: "response.output_item.done", output_index: 0, item: {type: "function_call", arguments: "{}"}}
    ].map { |event| "data: #{JSON.generate(event)}\n\n" }
    second = sse([
      {type: "response.created", response: {id: "second", model: "gpt-test"}},
      {type: "response.output_item.added", output_index: 0, item: {type: "function_call", call_id: "current", name: "current"}},
      {type: "response.function_call_arguments.delta", output_index: 0, delta: "{\"id\":1}"},
      {type: "response.output_item.done", output_index: 0, item: {type: "function_call", arguments: "{\"id\":1}"}},
      {type: "response.completed", response: {id: "second", model: "gpt-test", status: "completed"}}
    ])
    transport = Class.new do
      attr_reader :calls

      def initialize(first, second)
        @calls = 0
        @first = first
        @second = second
      end

      def stream(**)
        @calls += 1
        if calls == 1
          @first.each { |chunk| yield chunk }
          raise LittleGhost::Providers::HTTPError.new("lost", status: 503)
        end

        @second.each { |chunk| yield chunk }
      end
    end.new(first, second)

    events = provider(transport:, max_retries: 1, sleeper: ->(*) {}).stream(request).to_a
    retry_index = events.index { |event| event.type == :model_retry }
    response = events.last.data.fetch(:response)

    assert_equal 2, transport.calls
    assert events[0...retry_index].any? { |event| event.type == :tool_call_stop }
    assert_equal ["current"], response.message.content.grep(LittleGhost::Content::ToolUse).map(&:name)
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
  end

  def test_propagates_an_exhausted_transient_stream_failure_after_the_retry_boundary
    transport = Class.new do
      attr_reader :calls

      def initialize = @calls = 0

      def stream(**)
        @calls += 1
        yield "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        raise LittleGhost::Providers::HTTPError.new("lost", status: 503)
      end
    end.new
    delivered = []

    assert_raises(LittleGhost::Providers::HTTPError) do
      provider(transport:, max_retries: 1, sleeper: ->(*) {}).stream(request) { |event| delivered << event }
    end

    assert_equal 2, transport.calls
    assert_equal %i[text_delta model_retry text_delta], delivered.map(&:type)
  end

  def test_cancellation_is_checked_before_request
    transport = FakeTransport.new([])
    token = LittleGhost::Support::CancellationToken.new.cancel

    assert_raises(LittleGhost::CancelledError) { provider(transport:).stream(request(cancellation_token: token)).to_a }
    assert_empty transport.requests
  end

  def test_deadline_is_forwarded_to_the_http_transport
    transport = FakeTransport.new(["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    deadline = Time.now + 60

    provider(transport:).stream(request(deadline:)).to_a

    assert_equal deadline, transport.requests.first.fetch(:deadline)
  end

  def test_cancellation_interrupts_retry_backoff
    failure = LittleGhost::Providers::HTTPError.new("busy", status: 503)
    transport = FakeTransport.new(failure, ["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"])
    token = LittleGhost::Support::CancellationToken.new
    backoff_started = Queue.new
    retry_callback = ->(*) { backoff_started << true }
    runner = provider_thread(
      LittleGhost::Providers::OpenAI.new(
        api_key: "secret",
        model: "gpt-test",
        transport:,
        max_retries: 1,
        on_retry: retry_callback
      ),
      request(cancellation_token: token)
    )
    backoff_started.pop

    token.cancel

    assert runner.join(0.5), "OpenAI retry backoff did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
    assert_equal 1, transport.requests.length
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_retry_backoff_is_capped_by_the_deadline
    failure = LittleGhost::Providers::HTTPError.new("busy", status: 503)
    transport = FakeTransport.new(failure, [])
    delays = []
    retry_callback = ->(_attempt, _error, delay) { delays << delay }
    provider = LittleGhost::Providers::OpenAI.new(
      api_key: "secret",
      model: "gpt-test",
      transport:,
      max_retries: 1,
      on_retry: retry_callback
    )

    assert_raises(LittleGhost::DeadlineExceededError) do
      provider.stream(request(deadline: Time.now + 0.2)).to_a
    end

    assert_equal 1, transport.requests.length
    assert_equal 1, delays.length
    assert_operator delays.first, :>, 0
    assert_operator delays.first, :<=, 0.2
  end

  def test_normalizes_context_window_errors_for_agent_recovery
    failure = LittleGhost::Providers::HTTPError.new(
      "invalid request",
      status: 400,
      body: '{"error":{"code":"context_length_exceeded"}}'
    )

    error = assert_raises(LittleGhost::ContextWindowOverflowError) do
      provider(transport: FakeTransport.new(failure)).stream(request).to_a
    end

    assert_equal "The model context window was exceeded", error.message
  end

  def test_invalid_tool_json_raises_protocol_error
    events = [
      {type: "response.output_item.added", output_index: 0, item: {type: "function_call", call_id: "x", name: "bad"}},
      {type: "response.function_call_arguments.delta", output_index: 0, delta: "{"},
      {type: "response.output_item.done", output_index: 0, item: {type: "function_call", arguments: "{"}}
    ]

    assert_raises(LittleGhost::MalformedToolCallError) do
      provider(transport: FakeTransport.new(sse(events))).stream(request).to_a
    end
  end

  def test_missing_tool_identity_raises_protocol_error
    events = [
      {type: "response.output_item.added", output_index: 0, item: {type: "function_call", name: "lookup"}},
      {type: "response.output_item.done", output_index: 0, item: {type: "function_call", name: "lookup", arguments: "{}"}}
    ]

    error = assert_raises(LittleGhost::MalformedToolCallError) do
      provider(transport: FakeTransport.new(sse(events))).stream(request).to_a
    end
    assert_includes error.message, "tool use id is required"
  end

  def test_rejects_a_stream_that_ends_without_a_terminal_event
    transport = FakeTransport.new(["data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"])

    error = assert_raises(LittleGhost::ProtocolError) { provider(transport:).stream(request).to_a }
    assert_includes error.message, "terminal event"
  end

  def test_chat_stream_error_raises_provider_error
    transport = FakeTransport.new(sse([{error: {message: "overloaded"}}]))

    error = assert_raises(LittleGhost::ProviderError) do
      provider(transport:, api: :chat_completions).stream(request).to_a
    end
    assert_includes error.message, "overloaded"
  end

  def test_retries_transient_structured_stream_errors_before_output
    overloaded = sse([{type: "error", error: {message: "busy", metadata: {error_type: "provider_overloaded"}}}])
    completed = ["data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"]
    transport = FakeTransport.new(overloaded, completed)
    retries = []

    events = provider(
      transport:,
      max_retries: 1,
      on_retry: ->(*arguments) { retries << arguments }
    ).stream(request).to_a

    assert_equal 2, transport.requests.length
    assert_equal 1, retries.length
    assert_instance_of LittleGhost::Providers::OpenAICompatible::StreamError, retries.first.fetch(1)
    assert_equal :message_stop, events.last.type
  end

  def test_does_not_retry_permanent_structured_stream_errors
    invalid = sse([{type: "error", error: {message: "bad request", code: 400, type: "invalid_request"}}])
    transport = FakeTransport.new(invalid)

    assert_raises(LittleGhost::Providers::OpenAICompatible::StreamError) do
      provider(transport:, max_retries: 2).stream(request).to_a
    end

    assert_equal 1, transport.requests.length
  end

  private

  def provider(transport:, api: :responses, max_retries: 2, sleeper: ->(_) {}, on_retry: ->(*) {})
    LittleGhost::Providers::OpenAI.new(
      api_key: "secret",
      model: "gpt-test",
      transport:,
      api:,
      max_retries:,
      sleeper:,
      on_retry:
    )
  end

  def request(messages: [{role: :user, content: "Hello"}], tools: [], settings: {},
    cancellation_token: LittleGhost::Support::CancellationToken.new, deadline: nil)
    LittleGhost::ModelRequest.new(messages:, tools:, settings:, cancellation_token:, deadline:)
  end

  def sse(events)
    [events.map { |event| "data: #{JSON.generate(event)}\n\n" }.join, "data: [DONE]\n\n"]
  end

  def fragmented_sse(events)
    payload = sse(events).join
    [payload[0, 17], payload[17, 31], payload[48..]]
  end

  def chat_chunk(id:, delta:, finish_reason: nil)
    {id:, model: "gpt-test", choices: [{index: 0, delta:, finish_reason:}]}
  end

  def provider_thread(provider, model_request)
    Thread.new do
      provider.stream(model_request).to_a
    rescue => error
      error
    end.tap { |thread| thread.report_on_exception = false }
  end
end
