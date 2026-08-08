# frozen_string_literal: true

require "test_helper"

class ExecutionStateTest < Minitest::Test
  def test_state_is_isolated_between_threads
    ready = Queue.new
    release = Queue.new
    observed = Queue.new
    workers = %w[first second].map do |value|
      Thread.new do
        LittleGhost::ExecutionState.with(request_id: value) do
          ready << true
          release.pop
          observed << LittleGhost::ExecutionState[:request_id]
        end
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    workers.each(&:join)

    assert_equal %w[first second], 2.times.map { observed.pop }.sort
  end

  def test_state_is_isolated_between_interleaved_fibers
    observed = []
    fibers = %w[first second].map do |value|
      Fiber.new do
        LittleGhost::ExecutionState.with(request_id: value) do
          Fiber.yield
          observed << LittleGhost::ExecutionState[:request_id]
        end
      end
    end

    fibers.each(&:resume)
    fibers.each(&:resume)

    assert_equal %w[first second], observed
  end

  def test_child_fibers_inherit_a_snapshot_without_mutating_the_parent
    LittleGhost::ExecutionState.with(request_id: "parent") do
      child = Fiber.new do
        inherited = LittleGhost::ExecutionState[:request_id]
        LittleGhost::ExecutionState[:request_id] = "child"
        [inherited, LittleGhost::ExecutionState[:request_id]]
      end

      assert_equal %w[parent child], child.resume
      assert_equal "parent", LittleGhost::ExecutionState[:request_id]
    end
  end

  def test_framework_executor_propagates_state_to_worker_threads
    observed = LittleGhost::ExecutionState.with(request_id: "request-1") do
      LittleGhost::Support::Executor.new.map([:work]) do
        LittleGhost::ExecutionState[:request_id]
      end
    end

    assert_equal ["request-1"], observed
  end
end
