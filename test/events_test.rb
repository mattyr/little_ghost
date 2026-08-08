# frozen_string_literal: true

require "test_helper"
require "stringio"

class EventsTest < Minitest::Test
  class Listener
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event)
      @events << event
    end
  end

  def test_reports_structured_leveled_events
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)

    LittleGhost::Events.debug("model.request", model: "test")
    LittleGhost::Events.info("agent.ready", agent: "support")
    LittleGhost::Events.warn("provider.retry", attempt: 2)
    LittleGhost::Events.error("provider.failed", error_type: "Timeout")

    assert_equal %i[debug info warn error], listener.events.map { |event| event.fetch(:level) }
    assert_equal "model.request", listener.events.first.fetch(:name)
    assert_equal({model: "test"}, listener.events.first.fetch(:payload))
    assert_kind_of Integer, listener.events.first.fetch(:timestamp)
  end

  def test_context_is_scoped_to_the_current_execution
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)

    LittleGhost::Events.with_context(run_id: "run-1") do
      LittleGhost::Events.info("agent.started")
    end
    LittleGhost::Events.info("agent.started")

    assert_equal({run_id: "run-1"}, listener.events.first.fetch(:context))
    assert_empty listener.events.last.fetch(:context)
  end

  def test_context_is_isolated_between_interleaved_fibers
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)
    first = Fiber.new do
      LittleGhost::Events.with_context(run_id: "first") do
        Fiber.yield
        LittleGhost::Events.info("agent.ready")
      end
    end
    second = Fiber.new do
      LittleGhost::Events.with_context(run_id: "second") do
        Fiber.yield
        LittleGhost::Events.info("agent.ready")
      end
    end

    first.resume
    second.resume
    first.resume
    second.resume

    assert_equal %w[first second], listener.events.map { |event| event.dig(:context, :run_id) }
  end

  def test_listeners_can_filter_events
    listener = Listener.new
    LittleGhost::Events.subscribe(listener) { |event| event.fetch(:level) == :error }

    LittleGhost::Events.info("agent.ready")
    LittleGhost::Events.error("agent.failed")

    assert_equal ["agent.failed"], listener.events.map { |event| event.fetch(:name) }
  end

  def test_listener_failures_do_not_interrupt_other_listeners
    broken = Object.new
    broken.define_singleton_method(:emit) { |_| raise "unavailable" }
    listener = Listener.new
    LittleGhost::Events.subscribe(broken)
    LittleGhost::Events.subscribe(listener)

    LittleGhost::Events.warn("provider.retry")

    assert_equal ["provider.retry"], listener.events.map { |event| event.fetch(:name) }
  end

  def test_console_listener_writes_redacted_json_to_stderr
    output = StringIO.new
    listener = LittleGhost::Events::ConsoleListener.new(io: output)
    LittleGhost::Events.reporter = LittleGhost::Events::Reporter.new(listeners: [listener])

    LittleGhost::Events.info(
      "agent.ready",
      agent: "support",
      authorization: "Bearer abcdefghijklmnopqrstuvwxyz123456"
    )

    event = JSON.parse(output.string)
    assert_equal "agent.ready", event.fetch("name")
    assert_equal "info", event.fetch("level")
    assert_equal "support", event.dig("payload", "agent")
    assert_equal "[REDACTED]", event.dig("payload", "authorization")
  end

  def test_filters_receive_independent_events
    listener = Listener.new
    LittleGhost::Events.subscribe(listener) do |event|
      event[:name] = "changed"
      event[:payload][:nested][:value] = "changed"
      true
    end

    original = {nested: {value: "original"}}
    reported = LittleGhost::Events.error("agent.failed", original)

    assert_equal "agent.failed", listener.events.first.fetch(:name)
    assert_equal "original", listener.events.first.dig(:payload, :nested, :value)
    assert_equal "original", reported.dig(:payload, :nested, :value)
    assert_equal "original", original.dig(:nested, :value)
  end

  def test_cyclic_payloads_are_rejected_before_dispatch
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)
    payload = {}
    payload[:cycle] = payload

    error = assert_raises(ArgumentError) do
      LittleGhost::Events.info("agent.ready", payload)
    end

    assert_equal "event payload must not contain cycles", error.message
    assert_empty listener.events
  end

  def test_non_json_payload_values_are_rejected_before_dispatch
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)

    error = assert_raises(ArgumentError) do
      LittleGhost::Events.info("agent.ready", value: Struct.new(:secret).new("private"))
    end

    assert_equal "event payload values must be JSON-safe", error.message
    assert_empty listener.events
  end

  def test_invalid_utf8_is_normalized_before_dispatch
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)
    invalid = "bad\xFFvalue".dup.force_encoding(Encoding::UTF_8)

    LittleGhost::Events.info(invalid, invalid => invalid)

    event = listener.events.fetch(0)
    assert_equal "bad\uFFFDvalue", event.fetch(:name)
    assert_equal "bad\uFFFDvalue", event.dig(:payload, "bad\uFFFDvalue")
    assert JSON.generate(event)
  end

  def test_non_utf8_symbols_are_normalized_before_dispatch
    listener = Listener.new
    LittleGhost::Events.subscribe(listener)
    invalid = "bad\xFF".b.to_sym

    LittleGhost::Events.info("agent.ready", invalid => invalid)

    event = listener.events.fetch(0)
    assert_equal "bad\uFFFD", event.dig(:payload, "bad\uFFFD")
    assert JSON.generate(event)
  end
end
