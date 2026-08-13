# frozen_string_literal: true

require "test_helper"

class ExecutorTest < Minitest::Test
  def test_preserves_input_order_while_running_concurrently
    mutex = Mutex.new
    condition = ConditionVariable.new
    started = 0
    executor = LittleGhost::Support::Executor.new(max_concurrency: 2)

    results = executor.map([1, 2]) do |value|
      mutex.synchronize do
        started += 1
        condition.broadcast
        condition.wait(mutex) until started == 2
      end
      value * 2
    end

    assert_equal [2, 4], results
  end

  def test_propagates_worker_errors
    error = assert_raises(RuntimeError) do
      LittleGhost::Support::Executor.new.map([1]) { raise "boom" }
    end

    assert_equal "boom", error.message
  end

  def test_cleanup_errors_take_precedence_over_other_worker_errors
    cleanup_error = LittleGhost::CleanupError.new("parallel work is still running")
    mutex = Mutex.new
    condition = ConditionVariable.new
    started = 0

    raised = assert_raises(LittleGhost::CleanupError) do
      LittleGhost::Support::Executor.new(max_concurrency: 2).map(%i[deadline cleanup]) do |value|
        mutex.synchronize do
          started += 1
          condition.broadcast
          condition.wait(mutex) until started == 2
        end
        raise LittleGhost::DeadlineExceededError, "deadline" if value == :deadline

        raise cleanup_error
      end
    end

    assert_same cleanup_error, raised
  end

  def test_cancels_workers_before_waiting_after_a_completion_callback_fails
    token = LittleGhost::Support::CancellationToken.new
    started = Queue.new
    executor = LittleGhost::Support::Executor.new(max_concurrency: 2)

    error = assert_raises(RuntimeError) do
      executor.map([:fast, :waiting], cancellation_token: token, on_result: ->(*) { raise "consumer failed" }) do |value|
        if value == :waiting
          started << true
          loop do
            token.raise_if_cancelled!
            token.wait(0.01)
          end
        end
        started.pop
        :done
      end
    end

    assert_equal "consumer failed", error.message
    assert token.cancelled?
  end

  def test_preserves_the_causal_worker_error_over_cancellation_fallout
    token = LittleGhost::Support::CancellationToken.new
    waiting = Queue.new

    error = assert_raises(RuntimeError) do
      LittleGhost::Support::Executor.new(max_concurrency: 2).map([:waiting, :failure], cancellation_token: token) do |value|
        if value == :waiting
          waiting << true
          loop do
            token.raise_if_cancelled!
            token.wait(0.01)
          end
        end
        waiting.pop
        raise "causal failure"
      end
    end

    assert_equal "causal failure", error.message
  end
end
