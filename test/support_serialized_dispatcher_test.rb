# frozen_string_literal: true

require "test_helper"

class SupportSerializedDispatcherTest < Minitest::Test
  def test_queues_reentrant_delivery_behind_the_active_callback
    delivered = []
    dispatcher = nil
    dispatcher = LittleGhost::Support::SerializedDispatcher.new do |value|
      delivered << value
      dispatcher.call(:nested) if value == :outer
    end

    assert_equal :outer, dispatcher.call(:outer)
    assert_equal %i[outer nested], delivered
  end

  def test_serializes_competing_producers_with_backpressure
    entered = Queue.new
    release = Queue.new
    delivered = []
    dispatcher = LittleGhost::Support::SerializedDispatcher.new do |value|
      entered << true if value == :first
      release.pop if value == :first
      delivered << value
    end

    first = Thread.new { dispatcher.call(:first) }
    entered.pop
    second = Thread.new { dispatcher.call(:second) }
    Thread.pass until second.status == "sleep"

    assert_empty delivered
    release << true
    assert_equal :first, first.value
    assert_equal :second, second.value
    assert_equal %i[first second], delivered
  ensure
    release << true if release && release.empty?
    first&.join
    second&.join
  end

  def test_callback_failure_stops_queued_and_future_delivery
    failure = RuntimeError.new("delivery failed")
    delivered = []
    dispatcher = nil
    dispatcher = LittleGhost::Support::SerializedDispatcher.new do |value|
      delivered << value
      dispatcher.call(:nested)
      raise failure
    end

    assert_same failure, assert_raises(RuntimeError) { dispatcher.call(:outer) }
    assert_equal [:outer], delivered
    assert_same failure, assert_raises(RuntimeError) { dispatcher.call(:later) }
    assert_equal [:outer], delivered
  end
end
