# frozen_string_literal: true

require "test_helper"
require "little_ghost/providers/bedrock"

class BedrockTest < Minitest::Test
  FakeResponse = Data.define(:stream)
  NetworkingError = Class.new(StandardError)
  ServiceUnavailableException = Class.new(StandardError)
  ThrottlingException = Class.new(StandardError)

  class FakeClient
    attr_reader :parameters

    def initialize(events)
      @events = events
    end

    def converse_stream(**parameters)
      @parameters = parameters
      FakeResponse.new(stream: @events)
    end
  end

  class StalledEvents
    attr_reader :started

    def initialize
      @started = Queue.new
      @release = Queue.new
    end

    def each
      started << true
      @release.pop
    end
  end

  def test_normalizes_converse_stream_and_request
    events = [
      {message_start: {role: "assistant"}},
      {content_block_delta: {content_block_index: 0, delta: {text: "Hello"}}},
      {content_block_start: {content_block_index: 1, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 1, delta: {tool_use: {input: "{\"id\":1}"}}}},
      {content_block_stop: {content_block_index: 1}},
      {message_stop: {stop_reason: "tool_use"}},
      {metadata: {usage: {input_tokens: 10, output_tokens: 4, cache_read_input_tokens: 3}}}
    ]
    client = FakeClient.new(events)
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    tool = {name: "lookup", description: "Lookup", input_schema: {type: "object"}}
    request = LittleGhost::ModelRequest.new(
      messages: [{role: :system, content: "System"}, {role: :user, content: "Hi"}],
      tools: [tool],
      settings: {max_tokens: 100}
    )

    result = provider.stream(request).to_a

    assert_equal %i[message_start text_delta tool_call_start tool_call_delta tool_call_stop usage message_stop], result.map(&:type)
    response = result.last.data[:response]
    assert_equal :tool_use, response.stop_reason
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
    assert_equal 3, response.usage.cache_read_tokens
    assert_equal [{text: "System"}], client.parameters[:system]
    assert_equal 100, client.parameters.dig(:inference_config, :max_tokens)
    assert_equal "lookup", client.parameters.dig(:tool_config, :tools, 0, :tool_spec, :name)
  end

  def test_missing_sdk_has_actionable_error
    provider_class = Class.new(LittleGhost::Providers::Bedrock) do
      private

      def require(_name)
        raise LoadError
      end
    end

    error = assert_raises(LittleGhost::ConfigurationError) { provider_class.new(model: "test") }
    assert_includes error.message, "aws-sdk-bedrockruntime"
  end

  def test_accepts_the_event_type_shape_used_by_the_aws_sdk
    events = [
      {role: "assistant", event_type: :message_start},
      {content_block_index: 0, delta: {text: "Hello"}, event_type: :content_block_delta},
      {stop_reason: "end_turn", event_type: :message_stop}
    ]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    result = provider.stream(request).to_a

    assert_equal %i[message_start text_delta message_stop], result.map(&:type)
    assert_equal "Hello", result.last.data[:response].message.text
  end

  def test_preserves_native_signed_reasoning_for_the_next_tool_turn
    events = [
      {message_start: {role: "assistant"}},
      {content_block_delta: {content_block_index: 0, delta: {reasoning_content: {text: "private reasoning"}}}},
      {content_block_delta: {content_block_index: 0, delta: {reasoning_content: {signature: "signed-reasoning"}}}},
      {content_block_start: {content_block_index: 1, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 1, delta: {tool_use: {input: "{}"}}}},
      {content_block_stop: {content_block_index: 1}},
      {message_stop: {stop_reason: "tool_use"}}
    ]
    first_provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client: FakeClient.new(events))
    response = first_provider.stream(request).to_a.last.data.fetch(:response)
    reasoning = response.message.content.grep(LittleGhost::Content::Reasoning).fetch(0)
    tool_use = response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0)

    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    second_provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    second_provider.stream(request(messages: [
      response.message,
      {role: :tool, content: [LittleGhost::Content::ToolResult.new(tool_use_id: tool_use.id, content: "found", status: :success)]}
    ])).to_a

    assert_equal "private reasoning", reasoning.text
    assert_equal "signed-reasoning", reasoning.signature
    assert_equal({
      reasoning_content: {
        reasoning_text: {text: "private reasoning", signature: "signed-reasoning"}
      }
    }, client.parameters.dig(:messages, 0, :content, 0))
  end

  def test_serializes_redacted_bedrock_reasoning_natively
    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    provider = LittleGhost::Providers::Bedrock.new(model: "anthropic.test", client:)
    reasoning = LittleGhost::Content::Reasoning.new(redacted_content: "\x00encrypted".b)

    provider.stream(request(messages: [{role: :assistant, content: [reasoning]}])).to_a

    assert_equal({reasoning_content: {redacted_content: "\x00encrypted".b}}, client.parameters.dig(:messages, 0, :content, 0))
    assert_equal reasoning, LittleGhost::Content.normalize(reasoning.to_h)
  end

  def test_rejects_a_truncated_stream
    events = [{message_start: {role: "assistant"}}, {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}}]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    error = assert_raises(LittleGhost::ProtocolError) { provider.stream(request).to_a }
    assert_includes error.message, "message_stop"
  end

  def test_rejects_malformed_tool_calls_with_a_specific_error
    events = [
      {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "tool-1", name: "lookup"}}}},
      {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{"}}}},
      {content_block_stop: {content_block_index: 0}}
    ]
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(events))

    error = assert_raises(LittleGhost::MalformedToolCallError) { provider.stream(request).to_a }

    assert_includes error.message, "invalid tool call"
  end

  def test_cancellation_interrupts_a_stalled_stream
    stalled = StalledEvents.new
    token = LittleGhost::Support::CancellationToken.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(stalled))
    runner = provider_thread(provider, request(cancellation_token: token))
    stalled.started.pop

    token.cancel

    assert runner.join(1), "stalled Bedrock stream did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_deadline_interrupts_a_stalled_stream
    stalled = StalledEvents.new
    token = LittleGhost::Support::CancellationToken.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new(stalled))
    runner = provider_thread(provider, request(cancellation_token: token, deadline: Time.now + 0.05))
    stalled.started.pop

    assert runner.join(1), "stalled Bedrock stream did not stop at its deadline"
    assert_instance_of LittleGhost::DeadlineExceededError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_retries_transient_failures_and_reports_them
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy" if attempts == 1

        BedrockTest::FakeResponse.new(stream: [{message_stop: {stop_reason: "end_turn"}}])
      end
    end.new
    delays = []
    retries = []
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(delay) { delays << delay },
      on_retry: ->(*arguments) { retries << arguments }
    )

    provider.stream(request).to_a

    assert_equal 2, client.attempts
    assert_equal [1], delays
    assert_equal 1, retries.first.fetch(0)
    assert_instance_of NetworkingError, retries.first.fetch(1)
    assert_equal 1, retries.first.fetch(2)
  end

  def test_does_not_outer_retry_sdk_throttling_failures
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::ThrottlingException, "throttled"
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 2,
      sleeper: ->(*) { flunk("outer retry should not sleep for SDK throttling") }
    )

    assert_raises(LittleGhost::ProviderError) { provider.stream(request).to_a }
    assert_equal 1, client.attempts
  end

  def test_retries_terminal_service_failures
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::ServiceUnavailableException, "unavailable" if attempts == 1

        BedrockTest::FakeResponse.new(stream: [{message_stop: {stop_reason: "end_turn"}}])
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(*) {}
    )

    provider.stream(request).to_a

    assert_equal 2, client.attempts
  end

  def test_retries_a_transient_stream_failure_after_partial_output
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        if attempts > 1
          return BedrockTest::FakeResponse.new(stream: [
            {message_start: {role: "assistant"}},
            {content_block_delta: {content_block_index: 0, delta: {text: "complete"}}},
            {message_stop: {stop_reason: "end_turn"}}
          ])
        end

        stream = Enumerator.new do |output|
          output << {message_start: {role: "assistant"}}
          output << {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}}
          raise BedrockTest::NetworkingError, "lost"
        end
        BedrockTest::FakeResponse.new(stream:)
      end
    end.new
    delivered = []
    retries = []
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test",
      client:,
      max_retries: 1,
      sleeper: ->(*) {},
      on_retry: ->(*arguments) { retries << arguments }
    )

    provider.stream(request) { |event| delivered << event }

    assert_equal 2, client.attempts
    assert_equal 1, retries.length
    assert_equal %i[message_start text_delta model_retry message_start text_delta message_stop], delivered.map(&:type)
    assert_equal "complete", delivered.last.data.fetch(:response).message.text
  end

  def test_retries_after_a_partial_tool_call_and_returns_only_the_successful_attempt
    client = Class.new do
      attr_reader :attempts

      def initialize = @attempts = 0

      def converse_stream(**)
        @attempts += 1
        events = if attempts == 1
          [
            {message_start: {role: "assistant"}},
            {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "stale", name: "stale"}}}},
            {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{}"}}}},
            {content_block_stop: {content_block_index: 0}},
            {service_unavailable_exception: {message: "retry"}}
          ]
        else
          [
            {message_start: {role: "assistant"}},
            {content_block_start: {content_block_index: 0, start: {tool_use: {tool_use_id: "current", name: "current"}}}},
            {content_block_delta: {content_block_index: 0, delta: {tool_use: {input: "{\"id\":1}"}}}},
            {content_block_stop: {content_block_index: 0}},
            {message_stop: {stop_reason: "tool_use"}}
          ]
        end
        BedrockTest::FakeResponse.new(stream: events)
      end
    end.new

    events = LittleGhost::Providers::Bedrock.new(
      model: "test", client:, max_retries: 1, sleeper: ->(*) {}
    ).stream(request).to_a
    retry_index = events.index { |event| event.type == :model_retry }
    response = events.last.data.fetch(:response)

    assert_equal 2, client.attempts
    assert events[0...retry_index].any? { |event| event.type == :tool_call_stop }
    assert_equal ["current"], response.message.content.grep(LittleGhost::Content::ToolUse).map(&:name)
    assert_equal({"id" => 1}, response.message.content.grep(LittleGhost::Content::ToolUse).fetch(0).input)
  end

  def test_retries_modeled_transient_stream_errors_after_partial_output
    transient_types = %i[
      internal_server_exception model_stream_error_exception service_unavailable_exception throttling_exception
    ]

    transient_types.each do |type|
      client = Class.new do
        attr_reader :attempts

        define_method(:initialize) do |event_type|
          @event_type = event_type
          @attempts = 0
        end

        define_method(:converse_stream) do |**|
          @attempts += 1
          events = if attempts == 1
            [
              {message_start: {role: "assistant"}},
              {content_block_delta: {content_block_index: 0, delta: {text: "partial"}}},
              {@event_type => {message: "retryable stream failure"}}
            ]
          else
            [{message_start: {role: "assistant"}}, {message_stop: {stop_reason: "end_turn"}}]
          end
          BedrockTest::FakeResponse.new(stream: events)
        end
      end.new(type)
      events = LittleGhost::Providers::Bedrock.new(
        model: "test", client:, max_retries: 1, sleeper: ->(*) {}
      ).stream(request).to_a

      assert_equal 2, client.attempts, type
      assert_equal 1, events.count { |event| event.type == :model_retry }, type
    end
  end

  def test_does_not_retry_modeled_validation_stream_errors
    client = FakeClient.new([{validation_exception: {message: "invalid request"}}])
    provider = LittleGhost::Providers::Bedrock.new(
      model: "test", client:, max_retries: 2,
      sleeper: ->(*) { flunk("validation failures must not be retried") }
    )

    error = assert_raises(LittleGhost::Providers::Bedrock::StreamError) { provider.stream(request).to_a }

    assert_equal "validation_exception", error.event_type
  end

  def test_cancellation_interrupts_retry_backoff
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy"
      end
    end.new
    token = LittleGhost::Support::CancellationToken.new
    backoff_started = Queue.new
    retry_callback = ->(*) { backoff_started << true }
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:, max_retries: 1, on_retry: retry_callback)
    runner = provider_thread(provider, request(cancellation_token: token))
    backoff_started.pop

    token.cancel

    assert runner.join(0.5), "Bedrock retry backoff did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
    assert_equal 1, client.attempts
  ensure
    token&.cancel
    runner&.kill
    runner&.join
  end

  def test_retry_backoff_is_capped_by_the_deadline
    client = Class.new do
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def converse_stream(**)
        @attempts += 1
        raise BedrockTest::NetworkingError, "busy"
      end
    end.new
    delays = []
    retry_callback = ->(_attempt, _error, delay) { delays << delay }
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:, max_retries: 1, on_retry: retry_callback)

    assert_raises(LittleGhost::DeadlineExceededError) do
      provider.stream(request(deadline: Time.now + 0.2)).to_a
    end

    assert_equal 1, client.attempts
    assert_equal 1, delays.length
    assert_operator delays.first, :>, 0
    assert_operator delays.first, :<=, 0.2
  end

  def test_rejects_unsupported_reasoning_effort
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client: FakeClient.new([]))
    configured = LittleGhost::ModelRequest.new(
      messages: [{role: :user, content: "Hello"}],
      settings: {reasoning_effort: "high"}
    )

    error = assert_raises(LittleGhost::ConfigurationError) { provider.stream(configured).to_a }

    assert_equal "Bedrock does not support reasoning_effort", error.message
  end

  def test_normalizes_context_window_errors_for_agent_recovery
    client = Class.new do
      def converse_stream(**)
        raise BedrockTest::NetworkingError, "Input is too long for requested model"
      end
    end.new
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:)

    error = assert_raises(LittleGhost::ContextWindowOverflowError) do
      provider.stream(request).to_a
    end

    assert_equal "The model context window was exceeded", error.message
  end

  def test_maps_bedrock_media_formats
    client = FakeClient.new([{message_stop: {stop_reason: "end_turn"}}])
    provider = LittleGhost::Providers::Bedrock.new(model: "test", client:)
    messages = [{
      role: :user,
      content: [
        LittleGhost::Content::Image.new(data: "image", media_type: "image/jpeg"),
        LittleGhost::Content::Document.new(data: "document", media_type: "text/markdown", name: "notes.md")
      ]
    }]

    provider.stream(request(messages:)).to_a

    content = client.parameters.dig(:messages, 0, :content)
    assert_equal "jpeg", content[0].dig(:image, :format)
    assert_equal "md", content[1].dig(:document, :format)
  end

  private

  def request(messages: [{role: :user, content: "Hello"}],
    cancellation_token: LittleGhost::Support::CancellationToken.new, deadline: nil)
    LittleGhost::ModelRequest.new(messages:, cancellation_token:, deadline:)
  end

  def provider_thread(provider, model_request)
    Thread.new do
      provider.stream(model_request).to_a
    rescue => error
      error
    end.tap { |thread| thread.report_on_exception = false }
  end
end
