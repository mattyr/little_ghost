# frozen_string_literal: true

require "async"
require "test_helper"

class BlockingOperationTest < Minitest::Test
  def test_offloads_from_a_scheduled_fiber_and_propagates_execution_state
    result = nil

    Async do
      scheduler_thread = Thread.current
      LittleGhost::ExecutionState.with(blocking_operation_test: "present") do
        result = LittleGhost::Support::BlockingOperation.call do
          [Thread.current.equal?(scheduler_thread), LittleGhost::ExecutionState[:blocking_operation_test]]
        end
      end
    end

    assert_equal [false, "present"], result
  end

  def test_runs_inline_without_a_current_scheduler
    thread = Thread.current

    assert_same thread, LittleGhost::Support::BlockingOperation.call { Thread.current }
  end

  def test_bounds_and_reuses_workers_for_concurrent_scheduler_calls
    workers = Queue.new
    entered = Queue.new
    release = Queue.new

    Async do |task|
      50.times do
        task.async do
          workers << LittleGhost::Support::BlockingOperation.call do
            entered << true
            release.pop
            Thread.current
          end
        end
      end
      2.times { entered.pop }
      50.times { release << true }
    end.wait

    assert_equal 2, 50.times.map { workers.pop }.uniq.length
  ensure
    50.times { release&.push(true) }
  end

  def test_propagates_worker_errors
    error = nil

    Async do
      error = assert_raises(ArgumentError) do
        LittleGhost::Support::BlockingOperation.call { raise ArgumentError, "bad operation" }
      end
    end.wait

    assert_equal "bad operation", error.message
  end

  def test_worker_creation_failure_does_not_leave_the_operation_queued
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      first_operation_ran = false
      creation_attempts = 0
      original_new = Thread.method(:new)

      Thread.stub(:new, lambda { |*arguments, &block|
        creation_attempts += 1
        raise ThreadError, "unavailable" if creation_attempts == 1

        original_new.call(*arguments, &block)
      }) do
        Async do
          assert_raises(ThreadError) do
            LittleGhost::Support::BlockingOperation.call { first_operation_ran = true }
          end
          assert_equal :second, LittleGhost::Support::BlockingOperation.call { :second }
        end.wait
      end
      Marshal.dump(first_operation_ran, writer)
      writer.close
      exit! 0
    end
    writer.close

    refute Marshal.load(reader)
    _pid, status = Process.waitpid2(pid)
    assert_predicate status, :success?
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_cancellation_waits_for_the_submitted_operation
    started = Queue.new
    release = Queue.new
    completed = false
    cleaned = nil
    waiting_after_stop = false

    Async do |task|
      child = task.async do
        LittleGhost::Support::BlockingOperation.call(on_interruption: ->(value) { cleaned = value }) do
          started << true
          release.pop
          completed = true
          :completed
        end
      end
      started.pop

      child.stop
      waiting_after_stop = child.alive? && !completed
      release << true
      child.wait
    end.wait

    assert waiting_after_stop
    assert completed
    assert_equal :completed, cleaned
  ensure
    release&.push(true)
  end
end
