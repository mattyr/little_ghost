# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < Minitest::Test
  def test_observer_failures_do_not_interrupt_other_observers
    received = []
    events = []
    listener = Object.new
    listener.define_singleton_method(:emit) { |event| events << event }
    LittleGhost::Events.subscribe(listener)
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe { raise "boom" }
    instrumentation.subscribe { |name, attributes| received << [name, attributes] }

    instrumentation.publish(:model_started, model: "test")

    assert_equal [[:model_started, {model: "test"}]], received
    warning = events.fetch(0)
    assert_equal "little_ghost.instrumentation.listener_failed", warning.fetch(:name)
    assert_equal :warn, warning.fetch(:level)
    assert_equal :subscriber, warning.dig(:payload, :component)
    assert_equal "RuntimeError", warning.dig(:payload, :error_type)
  end

  def test_failure_events_do_not_recurse_through_instrumentation_bridges
    events = []
    bridge = Object.new
    bridge.define_singleton_method(:emit) do |event|
      events << event
      LittleGhost::Instrumentation.publish(:bridged_event)
    end
    LittleGhost::Events.subscribe(bridge)
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe { raise "unavailable" }

    instrumentation.publish(:model_started)

    assert_equal 1, events.length
    assert_equal "little_ghost.instrumentation.listener_failed", events.first.fetch(:name)
  end

  def test_repeated_instrumentation_failures_emit_one_operational_event
    events = []
    listener = Object.new
    listener.define_singleton_method(:emit) { |event| events << event }
    LittleGhost::Events.subscribe(listener)
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe { raise "unavailable" }

    instrumentation.publish(:first)
    instrumentation.publish(:second)

    assert_equal 1, events.length
    assert_equal "little_ghost.instrumentation.listener_failed", events.first.fetch(:name)
  end

  def test_subscribers_receive_independent_mutable_structured_attributes
    received = nil
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe do |_name, subscriber_attributes|
      subscriber_attributes[:invocation][:message][:content] << "changed"
    end
    instrumentation.subscribe { |name, attributes| received = [name, attributes] }
    attributes = {
      invocation: {message: {content: ["hello"]}},
      usage: {input_tokens: 3},
      outcomes: [true, false, nil]
    }

    returned = instrumentation.publish(:invocation_stop, **attributes)

    assert_equal [:invocation_stop, attributes], received
    assert_equal attributes, returned
    refute returned.frozen?
    refute returned.fetch(:invocation).frozen?
    refute returned.dig(:invocation, :message, :content).frozen?
  end

  def test_distinct_equal_subscribers_are_both_notified
    subscriber_class = Struct.new(:events) do
      def call(name, *) = events << name
    end
    first = subscriber_class.new([])
    second = subscriber_class.new([])
    assert_equal first, second

    LittleGhost::Instrumentation.subscribe(first)
    LittleGhost::Instrumentation.subscribe(second)
    LittleGhost::Instrumentation.publish(:model_started)

    assert_equal [:model_started], first.events
    assert_equal [:model_started], second.events
  end

  def test_diagnostic_content_is_disabled_by_default
    received = nil
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.publish(:model_start, model_id: "test", diagnostic: {input: {message: "private"}})

    assert_equal({model_id: "test"}, received)
  end

  def test_explicit_content_capture_scrubs_secrets_and_applies_enrichers
    received = nil
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: LittleGhost::Support::ContentCapture.new(
        enabled: true,
        redactions: ["internal-arbitrary-value"]
      ),
      enrichers: [->(_name, attributes) { {tags: ["test"], copied_model: attributes[:model_id]} }]
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.publish(
      :model_start,
      model_id: "model-1",
      diagnostic: {
        input: {
          authorization: "Bearer secret-value",
          message: "Use Bearer abcdefghijklmnopqrstuvwxyz123456 and internal-arbitrary-value"
        }
      }
    )

    captured = JSON.parse(received.fetch(:diagnostic_input))
    assert_equal "[REDACTED]", captured.fetch("authorization")
    assert_equal "Use [REDACTED] and [REDACTED]", captured.fetch("message")
    assert_equal ["test"], received.fetch(:tags)
    assert_equal "model-1", received.fetch(:copied_model)
  end

  def test_captured_content_is_bounded_and_remains_valid_json
    policy = LittleGhost::Support::ContentCapture.new(enabled: true, max_bytes: 128)

    value = policy.capture({input: {message: "é" * 500}}).fetch(:diagnostic_input)

    assert_operator value.bytesize, :<=, 128
    assert_equal true, JSON.parse(value).fetch("truncated")
  end

  def test_captured_content_is_lossless_by_default
    policy = LittleGhost::Support::ContentCapture.new(enabled: true)
    message = "é" * 100_000

    value = policy.capture(input: {message:}).fetch(:diagnostic_input)

    assert_operator value.bytesize, :>, 64_000
    assert_equal message, JSON.parse(value).fetch("message")
  end

  def test_captured_content_normalizes_invalid_utf8
    policy = LittleGhost::Support::ContentCapture.new(enabled: true)
    message = "ok\xFFbad".dup.force_encoding(Encoding::UTF_8)

    value = policy.capture(input: {message:}).fetch(:diagnostic_input)

    assert_equal "ok\uFFFDbad", JSON.parse(value).fetch("message")
  end

  def test_exception_capture_is_scrubbed
    policy = LittleGhost::Support::ContentCapture.new(enabled: true)

    captured = policy.capture(
      exception: {
        type: "ProviderError",
        message: "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456",
        api_key: "secret"
      }
    )
    exception = JSON.parse(captured.fetch(:diagnostic_exception))

    assert_equal "ProviderError", exception.fetch("type")
    assert_equal "Authorization: [REDACTED]", exception.fetch("message")
    assert_equal "[REDACTED]", exception.fetch("api_key")
  end

  def test_json_string_output_is_structured_and_scrubbed
    policy = LittleGhost::Support::ContentCapture.new(enabled: true)

    captured = policy.capture(
      output: JSON.generate(
        password: "arbitrary-secret",
        result: "found"
      )
    )
    output = JSON.parse(captured.fetch(:diagnostic_output))

    assert_equal "[REDACTED]", output.fetch("password")
    assert_equal "found", output.fetch("result")
  end

  def test_custom_scrubber_cannot_reintroduce_sensitive_output
    policy = LittleGhost::Support::ContentCapture.new(
      enabled: true,
      scrubber: ->(_value) { {authorization: "Bearer abcdefghijklmnopqrstuvwxyz123456"} }
    )

    output = JSON.parse(policy.capture(output: "found").fetch(:diagnostic_output))

    assert_equal "[REDACTED]", output.fetch("authorization")
  end

  def test_tool_definition_capture_is_scrubbed_and_bounded
    policy = LittleGhost::Support::ContentCapture.new(enabled: true, max_bytes: 256)

    captured = policy.capture(
      tool_definitions: [{
        name: "lookup",
        description: "Uses Bearer abcdefghijklmnopqrstuvwxyz123456 #{"x" * 1_000}",
        input_schema: {properties: {api_key: {default: "secret"}}}
      }]
    )
    definitions = JSON.parse(captured.fetch(:diagnostic_tool_definitions))

    assert_operator captured.fetch(:diagnostic_tool_definitions).bytesize, :<=, 256
    serialized = JSON.generate(definitions)
    refute_includes serialized, "abcdefghijklmnopqrstuvwxyz123456"
    refute_includes serialized, "secret"
  end

  def test_tool_definition_capture_is_lossless_by_default
    policy = LittleGhost::Support::ContentCapture.new(enabled: true)
    description = "x" * 100_000

    captured = policy.capture(
      tool_definitions: [{name: "lookup", description:, input_schema: {type: "object"}}]
    )
    definition = JSON.parse(captured.fetch(:diagnostic_tool_definitions)).first

    assert_equal description, definition.fetch("description")
  end

  def test_instrumentation_captures_tool_definitions_from_diagnostic_payload
    received = nil
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.publish(
      :model_start,
      diagnostic: {tool_definitions: [{name: "lookup", input_schema: {type: "object"}}]}
    )

    definitions = JSON.parse(received.fetch(:diagnostic_tool_definitions))
    assert_equal "lookup", definitions.first.fetch("name")
  end

  def test_oversized_tool_definitions_stop_capture_without_a_preview
    policy = LittleGhost::Support::ContentCapture.new(enabled: true, max_bytes: 128)
    definitions = Array.new(100_000, {name: "lookup", description: "x" * 100})

    captured = policy.capture(tool_definitions: definitions)

    assert_equal({"truncated" => true}, JSON.parse(captured.fetch(:diagnostic_tool_definitions)))
  end

  def test_tool_definition_capture_honors_custom_scrubbers
    policy = LittleGhost::Support::ContentCapture.new(
      enabled: true,
      scrubber: ->(value) {
        value.map { |definition| definition.merge("description" => "[CUSTOM REDACTION]") }
      }
    )

    captured = policy.capture(tool_definitions: [{name: "lookup", description: "private domain detail"}])
    definition = JSON.parse(captured.fetch(:diagnostic_tool_definitions)).first

    assert_equal "[CUSTOM REDACTION]", definition.fetch("description")
  end

  def test_capture_normalizes_camel_case_secret_keys_and_isolates_policy_failures
    captured = LittleGhost::Support::ContentCapture.new(enabled: true).capture(
      {input: {callbackToken: "secret-callback-value", privateKey: "private-key-value"}}
    )
    content = JSON.parse(captured.fetch(:diagnostic_input))
    assert_equal "[REDACTED]", content.fetch("callbackToken")
    assert_equal "[REDACTED]", content.fetch("privateKey")

    received = nil
    broken = Object.new
    broken.define_singleton_method(:capture) { |_| raise "scrubber unavailable" }
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: broken
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.publish(:model_start, model_id: "model-1", diagnostic: {input: "private"})

    assert_equal({model_id: "model-1"}, received)
  end

  def test_instrumentation_owns_subscriber_lifecycle_and_forwards_trace_attributes
    subscriber = ->(*) {}
    flushed = false
    shutdown = false
    trace_attributes = nil
    subscriber.define_singleton_method(:flush) { flushed = true }
    subscriber.define_singleton_method(:shutdown) { |timeout:| shutdown = timeout }
    subscriber.define_singleton_method(:trace_context) do |**attributes|
      trace_attributes = attributes
      {trace_id: "trace"}
    end

    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(subscribers: [subscriber])
    instrumentation.flush
    instrumentation.shutdown(timeout: 2)

    assert flushed
    assert_operator shutdown, :<=, 2
    assert_equal({trace_id: "trace"}, instrumentation.trace_context(operation_id: "run-1"))
    assert_equal({operation_id: "run-1"}, trace_attributes)
  end

  def test_run_publishes_model_retries_as_semantic_telemetry
    recorded = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe { |name, attributes| recorded << [name, attributes] }
    runtime = TestRuntime.new
    invocation = LittleGhost::Invocation.new(message: "Hello")
    run = LittleGhost::Run.new(runtime:, agent_class: LittleGhost::Agent, invocation:)

    run.publish(
      :model_retry,
      attempt: 2,
      delay: 0.5,
      error: RuntimeError.new("credential leaked"),
      error_code: "server_error",
      http_status: 503,
      partial_text: true,
      private: "ignored"
    )
    run.publish(:model_retry, attempt: 3, error: "provider included secret text")

    name, attributes = recorded.fetch(0)
    assert_equal :model_retry, name
    assert_equal 2, attributes.fetch(:attempt)
    assert_equal 0.5, attributes.fetch(:delay)
    assert_equal "RuntimeError", attributes.fetch(:error_class)
    assert_equal "server_error", attributes.fetch(:error_code)
    assert_equal 503, attributes.fetch(:http_status)
    assert_equal true, attributes.fetch(:partial_text)
    refute attributes.key?(:error)
    refute attributes.key?(:private)
    assert_equal invocation.run_id, attributes.fetch(:run_id)
    refute recorded.fetch(1).last.key?(:error_class)
  end

  def test_lifecycle_failures_are_isolated
    subscriber = ->(*) {}
    subscriber.define_singleton_method(:flush) { raise "unavailable" }
    subscriber.define_singleton_method(:shutdown) { |timeout:| raise "unavailable" }
    subscriber.define_singleton_method(:trace_context) { |**| raise "unavailable" }
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(subscribers: [subscriber])

    instrumentation.flush
    instrumentation.shutdown
    assert_empty instrumentation.trace_context(operation_id: "run-1")
  end

  def test_context_is_isolated_between_interleaved_fibers
    observed = []
    first = Fiber.new do
      LittleGhost::Instrumentation.with_context(run_id: "first") do
        Fiber.yield
        observed << LittleGhost::Instrumentation.context.fetch(:run_id)
      end
    end
    second = Fiber.new do
      LittleGhost::Instrumentation.with_context(run_id: "second") do
        Fiber.yield
        observed << LittleGhost::Instrumentation.context.fetch(:run_id)
      end
    end

    first.resume
    second.resume
    first.resume
    second.resume

    assert_equal %w[first second], observed
  end

  def test_subscribers_can_publish_nested_instrumentation
    received = []
    subscriber = lambda do |name, _attributes|
      LittleGhost::Instrumentation.publish(:nested) if name == :outer
    end
    LittleGhost::Instrumentation.subscribe(subscriber)
    LittleGhost::Instrumentation.subscribe { |name, _attributes| received << name }

    LittleGhost::Instrumentation.publish(:outer)

    assert_equal %i[nested outer], received
  end

  def test_scoped_subscription_is_removed_after_the_block
    received = []
    subscriber = ->(name, _attributes) { received << name }

    LittleGhost::Instrumentation.subscribed(subscriber) do
      LittleGhost::Instrumentation.publish(:inside)
    end
    LittleGhost::Instrumentation.publish(:outside)

    assert_equal [:inside], received
  end
end
