# frozen_string_literal: true

require "test_helper"

class RunOnceTest < Minitest::Test
  def test_runs_the_block_once_and_retries_after_a_failure
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "hello"),
      runtime: TestRuntime.new,
      agent_class: LittleGhost::Agent
    )
    calls = 0

    assert_raises(RuntimeError) do
      run.once(:setup) do
        calls += 1
        raise "failed"
      end
    end
    assert_equal :complete, run.once(:setup) {
      calls += 1
      :complete
    }
    assert_nil run.once(:setup) { calls += 1 }

    assert_equal 2, calls
  ensure
    run&.close
  end

  def test_serializes_competing_once_calls
    run = LittleGhost::Run.new(
      invocation: LittleGhost::Invocation.new(message: "hello"),
      runtime: TestRuntime.new,
      agent_class: LittleGhost::Agent
    )
    calls = 0
    mutex = Mutex.new

    4.times.map do
      Thread.new do
        run.once(:setup) do
          mutex.synchronize { calls += 1 }
        end
      end
    end.each(&:join)

    assert_equal 1, calls
  ensure
    run&.close
  end
end
