# frozen_string_literal: true

require "async"
require "test_helper"

class PooledThreadRunnerTest < Minitest::Test
  def test_public_helper_offloads_from_a_scheduled_fiber
    operation_thread = nil
    scheduler_thread = nil

    Async do
      scheduler_thread = Thread.current
      LittleGhost.offload_blocking { operation_thread = Thread.current }
    end

    refute_same scheduler_thread, operation_thread
  end

  def test_public_helper_runs_inline_without_a_current_scheduler
    assert_same Thread.current, LittleGhost.offload_blocking { Thread.current }
  end

  def test_public_helper_requires_a_block
    error = assert_raises(ArgumentError) { LittleGhost.offload_blocking }

    assert_equal "a blocking operation block is required", error.message
  end

  def test_public_helper_propagates_execution_state
    observed = nil

    Async do
      LittleGhost::ExecutionState.with(request_id: "request-1") do
        observed = LittleGhost.offload_blocking do
          [LittleGhost::ExecutionState[:request_id], Thread.current]
        end
      end
    end

    assert_equal "request-1", observed.first
    refute_same Thread.current, observed.last
  end

  def test_bounds_and_reuses_workers_for_concurrent_scheduler_calls
    workers = Queue.new
    entered = Queue.new
    release = Queue.new

    Async do |task|
      50.times do
        task.async do
          workers << LittleGhost.offload_blocking do
            entered << true
            release.pop
            Thread.current
          end
        end
      end
      LittleGhost.configuration.blocking_pool_capacity.times { entered.pop }
      50.times { release << true }
    end.wait

    assert_equal LittleGhost.configuration.blocking_pool_capacity, 50.times.map { workers.pop }.uniq.length
  ensure
    50.times { release&.push(true) }
  end

  def test_configured_capacity_is_shared_by_every_configuration
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      configuration = LittleGhost::Configuration.new
      configuration.blocking_pool_capacity = 3
      another_configuration = LittleGhost::Configuration.new
      Marshal.dump(
        [configuration.blocking_pool_capacity, another_configuration.blocking_pool_capacity],
        writer
      )
      writer.close
      exit! 0
    end
    writer.close

    assert_equal [3, 3], Marshal.load(reader)
    _pid, status = Process.waitpid2(pid)
    assert_predicate status, :success?
  ensure
    reader&.close
    writer&.close unless writer&.closed?
  end

  def test_configured_capacity_rejects_invalid_values
    configuration = LittleGhost::Configuration.new
    error = assert_raises(ArgumentError) { configuration.blocking_pool_capacity = 0 }

    assert_equal "blocking_pool_capacity must be a positive integer", error.message
    assert_raises(ArgumentError) { configuration.blocking_pool_capacity = 2.9 }
  end

  def test_configured_capacity_cannot_change_after_the_pool_starts
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Async { LittleGhost.offload_blocking { nil } }.wait
      error = begin
        LittleGhost::Configuration.new.blocking_pool_capacity = 3
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

  def test_public_helper_propagates_worker_errors
    error = nil

    Async do
      error = assert_raises(ArgumentError) do
        LittleGhost.offload_blocking { raise ArgumentError, "bad operation" }
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
        LittleGhost.offload_blocking do
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

  def test_nested_offload_runs_inline_on_the_pool_worker
    observed = nil

    Async do
      observed = LittleGhost.offload_blocking do
        outer = Thread.current
        [outer, LittleGhost.offload_blocking { Thread.current }]
      end
    end

    assert_same observed.first, observed.last
  end

  def test_nested_offload_stays_inline_after_the_pool_worker_enters_a_scheduler
    runner = LittleGhost::Support::PooledThreadRunner.new(capacity: 1)
    executor = LittleGhost::Support::Executor.new(runner:)
    observed = nil

    Async do
      observed = executor.call do
        outer = Thread.current
        nested = Async { executor.call { Thread.current } }.wait
        [outer, nested]
      end
    end.wait

    assert_same observed.first, observed.last
  end

  def test_pooled_task_cannot_terminate_its_shared_worker
    started = Queue.new
    release = Queue.new
    task = LittleGhost::Support::Executor.blocking.submit do
      started << true
      release.pop
    end
    started.pop

    refute task.terminate
    release << true
    task.wait(deadline: Time.now + 1)
    refute_predicate task, :alive?
  ensure
    release&.push(true)
  end
end
