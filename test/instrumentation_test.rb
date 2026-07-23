# frozen_string_literal: true

require "test_helper"

class InstrumentationTest < Minitest::Test
  def test_observer_failures_do_not_interrupt_other_observers
    received = []
    instrumentation = LittleGhost::Support::Instrumentation.new(logger: Logger.new(IO::NULL))
    instrumentation.subscribe { raise "boom" }
    instrumentation.subscribe { |name, attributes| received << [name, attributes] }

    instrumentation.emit(:model_started, model: "test")

    assert_equal [[:model_started, {model: "test"}]], received
  end

  def test_instrumentation_preserves_and_deep_freezes_structured_attributes
    received = nil
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe { |name, attributes| received = [name, attributes] }
    attributes = {
      invocation: {message: {content: ["hello"]}},
      usage: {input_tokens: 3},
      outcomes: [true, false, nil]
    }

    returned = instrumentation.emit(:invocation_stop, **attributes)

    assert_equal [:invocation_stop, attributes], received
    assert_same returned, received.last
    assert returned.frozen?
    assert returned.fetch(:invocation).frozen?
    assert returned.dig(:invocation, :message, :content).frozen?
    assert returned.dig(:invocation, :message, :content, 0).frozen?
  end

  def test_diagnostic_content_is_disabled_by_default
    received = nil
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.emit(:model_start, model_id: "test", diagnostic: {input: {message: "private"}})

    assert_equal({model_id: "test"}, received)
  end

  def test_explicit_content_capture_scrubs_secrets_and_applies_enrichers
    received = nil
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(
        enabled: true,
        redactions: ["internal-arbitrary-value"]
      ),
      enrichers: [->(_name, attributes) { {tags: ["test"], copied_model: attributes[:model_id]} }]
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.emit(
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

  def test_instrumentation_captures_tool_definitions_from_diagnostic_payload
    received = nil
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.emit(
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
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: broken,
      logger: Logger.new(IO::NULL)
    )
    instrumentation.subscribe { |_name, attributes| received = attributes }

    instrumentation.emit(:model_start, model_id: "model-1", diagnostic: {input: "private"})

    assert_equal({model_id: "model-1"}, received)
  end

  def test_instrumentation_owns_subscriber_lifecycle_and_forwards_trace_attributes
    subscriber = ->(*) {}
    flushed = false
    shutdown = false
    trace_attributes = nil
    subscriber.define_singleton_method(:flush) { flushed = true }
    subscriber.define_singleton_method(:shutdown) { shutdown = true }
    subscriber.define_singleton_method(:trace_context) do |**attributes|
      trace_attributes = attributes
      {trace_id: "trace"}
    end

    instrumentation = LittleGhost::Support::Instrumentation.new(subscribers: [subscriber])
    instrumentation.flush
    instrumentation.shutdown

    assert flushed
    assert shutdown
    assert_equal({trace_id: "trace"}, instrumentation.trace_context(operation_id: "run-1"))
    assert_equal({operation_id: "run-1"}, trace_attributes)
  end

  def test_run_publishes_model_retries_as_semantic_telemetry
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe { |name, attributes| recorded << [name, attributes] }
    application = Struct.new(:instrumentation).new(instrumentation)
    invocation = LittleGhost::Invocation.new(message: "Hello")
    run = LittleGhost::Run.new(application:, invocation:)

    run.publish(:model_retry, attempt: 2, delay: 0.5, error: RuntimeError.new("credential leaked"), private: "ignored")
    run.publish(:model_retry, attempt: 3, error: "provider included secret text")

    name, attributes = recorded.fetch(0)
    assert_equal :model_retry, name
    assert_equal 2, attributes.fetch(:attempt)
    assert_equal 0.5, attributes.fetch(:delay)
    assert_equal "RuntimeError", attributes.fetch(:error_class)
    refute attributes.key?(:error)
    refute attributes.key?(:private)
    assert_equal invocation.run_id, attributes.fetch(:run_id)
    refute recorded.fetch(1).last.key?(:error_class)
  end

  def test_lifecycle_failures_are_isolated
    subscriber = ->(*) {}
    subscriber.define_singleton_method(:flush) { raise "unavailable" }
    subscriber.define_singleton_method(:shutdown) { raise "unavailable" }
    subscriber.define_singleton_method(:trace_context) { |**| raise "unavailable" }
    instrumentation = LittleGhost::Support::Instrumentation.new(
      subscribers: [subscriber],
      logger: Logger.new(IO::NULL)
    )

    instrumentation.flush
    instrumentation.shutdown
    assert_empty instrumentation.trace_context(operation_id: "run-1")
  end
end
