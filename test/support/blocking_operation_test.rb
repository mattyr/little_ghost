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
end
