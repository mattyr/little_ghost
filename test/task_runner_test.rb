# frozen_string_literal: true

require "test_helper"
require "async"

class TaskRunnerTest < Minitest::Test
  def test_thread_task_propagates_state
    observed = nil
    task = LittleGhost::ExecutionState.with(request_id: "request-1") do
      LittleGhost::Support::TaskRunner.new(backend: :thread).spawn do
        observed = [
          LittleGhost::ExecutionState[:request_id],
          LittleGhost::Support::Task.current.current?
        ]
      end
    end

    task.wait(deadline: Time.now + 1)
    assert_equal ["request-1", true], observed
    refute_predicate task, :alive?
  end

  def test_records_the_worker_error
    error = RuntimeError.new("worker failed")
    task = LittleGhost::Support::TaskRunner.new(backend: :thread).spawn { raise error }

    task.wait(deadline: Time.now + 1)

    assert_same error, task.error
  end

  def test_wait_deadline_does_not_stop_the_task
    release = Queue.new
    task = LittleGhost::Support::TaskRunner.new(backend: :thread).spawn { release.pop }

    assert_raises(LittleGhost::DeadlineExceededError) do
      task.wait(deadline: Time.now - 1)
    end
    assert_predicate task, :alive?

    release << :finished
    task.wait(deadline: Time.now + 1)
    refute_predicate task, :alive?
  ensure
    release << :finished if task&.alive?
    task&.wait(deadline: Time.now + 1)
  end

  def test_terminate_only_force_stops_thread_tasks
    started = Queue.new
    release = Queue.new
    thread_task = LittleGhost::Support::TaskRunner.new(backend: :thread).spawn do
      started << true
      release.pop
    end
    started.pop

    assert thread_task.terminate
    thread_task.wait(deadline: Time.now + 1)
    refute_predicate thread_task, :alive?

    Async do
      fiber_task = LittleGhost::Support::TaskRunner.new(backend: :fiber).spawn do
        release.pop
      end

      refute fiber_task.terminate
      release << true
      fiber_task.wait(deadline: Time.now + 1)
      refute_predicate fiber_task, :alive?
    end.wait
  ensure
    release << true if thread_task&.alive?
    thread_task&.wait(deadline: Time.now + 1)
  end
end
