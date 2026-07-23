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

    raised = assert_raises(LittleGhost::CleanupError) do
      LittleGhost::Support::Executor.new(max_concurrency: 2).map(%i[deadline cleanup]) do |value|
        raise LittleGhost::DeadlineExceededError, "deadline" if value == :deadline

        raise cleanup_error
      end
    end

    assert_same cleanup_error, raised
  end
end
