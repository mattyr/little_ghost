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
