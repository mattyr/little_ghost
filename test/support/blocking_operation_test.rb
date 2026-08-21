# frozen_string_literal: true

require "async"
require "test_helper"

class BlockingOperationTest < Minitest::Test
  def test_offloads_from_a_scheduled_fiber
    operation_thread = nil
    scheduler_thread = nil

    Async do
      scheduler_thread = Thread.current
      LittleGhost::Support::BlockingOperation.call do
        operation_thread = Thread.current
      end
    end

    refute_same scheduler_thread, operation_thread
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
      LittleGhost.blocking_pool_capacity.times { entered.pop }
      50.times { release << true }
    end.wait

    assert_equal LittleGhost.blocking_pool_capacity, 50.times.map { workers.pop }.uniq.length
  ensure
    50.times { release&.push(true) }
  end

  def test_global_capacity_can_be_set_before_the_pool_starts
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      LittleGhost.blocking_pool_capacity = 3
      Marshal.dump(LittleGhost.blocking_pool_capacity, writer)
      writer.close
      exit! 0
    end
    writer.close

    assert_equal 3, Marshal.load(reader)
    _pid, status = Process.waitpid2(pid)
    assert_predicate status, :success?
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_global_capacity_rejects_invalid_values
    error = assert_raises(ArgumentError) { LittleGhost.blocking_pool_capacity = 0 }

    assert_equal "blocking_pool_capacity must be a positive integer", error.message
    assert_raises(ArgumentError) { LittleGhost.blocking_pool_capacity = 2.9 }
  end

  def test_global_capacity_cannot_change_after_the_pool_starts
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Async { LittleGhost::Support::BlockingOperation.call { nil } }.wait
      error = begin
        LittleGhost.blocking_pool_capacity = 3
        nil
      rescue => caught
        caught
      end
      Marshal.dump([error.class.name, error.message], writer)
      writer.close
      exit! 0
    end
    writer.close

    assert_equal [
      "LittleGhost::ConfigurationError",
      "blocking_pool_capacity cannot change after the blocking pool starts"
    ], Marshal.load(reader)
    _pid, status = Process.waitpid2(pid)
    assert_predicate status, :success?
  ensure
    reader&.close
    writer&.close unless writer&.closed?
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

  def test_cancellation_waits_for_the_submitted_operation
    started = Queue.new
    release = Queue.new
    completed = false
    waiting_after_stop = false

    Async do |task|
      child = task.async do
        LittleGhost::Support::BlockingOperation.call do
          started << true
          release.pop
          completed = true
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
  ensure
    release&.push(true)
  end
end
