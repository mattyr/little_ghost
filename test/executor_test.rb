# frozen_string_literal: true

require "test_helper"
require "async"

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

  def test_auto_backend_uses_scheduler_fibers_on_the_calling_thread
    observations = nil
    Async do
      calling_thread = Thread.current.object_id
      calling_fiber = Fiber.current.object_id
      mutex = Mutex.new
      condition = ConditionVariable.new
      started = 0
      executor = LittleGhost::Support::Executor.new(max_concurrency: 2)

      observations = executor.map(%i[first second]) do
        mutex.synchronize do
          started += 1
          condition.broadcast
          condition.wait(mutex) until started == 2
        end
        [Thread.current.object_id, Fiber.current.object_id, LittleGhost::Support::Task.current.backend]
      end

      assert observations.all? { |thread_id, _fiber_id, _backend| thread_id == calling_thread }
      assert observations.all? { |_thread_id, fiber_id, _backend| fiber_id != calling_fiber }
      assert_equal %i[fiber fiber], observations.map(&:last)
      assert_equal 2, observations.map { |observation| observation.fetch(1) }.uniq.length
    end.wait
  end

  def test_thread_backend_forces_worker_threads_inside_a_scheduler
    observations = nil
    Async do
      calling_thread = Thread.current.object_id
      runner = LittleGhost::Support::TaskRunner.new(backend: :thread)
      observations = LittleGhost::Support::Executor.new(task_runner: runner).map([:work]) do
        [Thread.current.object_id, LittleGhost::Support::Task.current.backend]
      end

      refute_equal calling_thread, observations.first.first
      assert_equal :thread, observations.first.last
    end.wait
  end

  def test_fiber_backend_requires_a_managed_scheduler_fiber
    runner = LittleGhost::Support::TaskRunner.new(backend: :fiber)

    error = assert_raises(LittleGhost::ConfigurationError) { runner.spawn { :work } }

    assert_includes error.message, "active scheduler-managed nonblocking fiber"
  end

  def test_auto_backend_does_not_use_a_scheduler_from_the_blocking_root_fiber
    scheduler = Object.new
    scheduler.define_singleton_method(:block) { |*| nil }
    scheduler.define_singleton_method(:unblock) { |*| nil }
    scheduler.define_singleton_method(:kernel_sleep) { |*| nil }
    scheduler.define_singleton_method(:io_wait) { |*| nil }
    scheduler.define_singleton_method(:fiber_interrupt) { |*| nil }
    scheduler.define_singleton_method(:fiber) { raise "root fiber must not schedule work" }
    scheduler.define_singleton_method(:close) {}
    Fiber.set_scheduler(scheduler)

    task = LittleGhost::Support::TaskRunner.new.spawn { LittleGhost::Support::Task.current.backend }

    assert_equal :thread, task.value(deadline: Time.now + 1)
  ensure
    Fiber.set_scheduler(nil)
  end
end
