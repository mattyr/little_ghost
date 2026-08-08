# frozen_string_literal: true

require "test_helper"

class InterruptibleStreamTest < Minitest::Test
  def test_producer_threads_receive_the_calling_execution_state
    token = LittleGhost::Support::CancellationToken.new
    stream = LittleGhost::Support::InterruptibleStream.new(cancellation_token: token) do |emit|
      emit.call(LittleGhost::ExecutionState[:request_id])
    end

    result = LittleGhost::ExecutionState.with(request_id: "request-1") { stream.to_a }

    assert_equal ["request-1"], result
  end

  def test_cancellation_fails_when_the_producer_does_not_quiesce
    token = LittleGhost::Support::CancellationToken.new
    runner, worker, cleanup_started, release = stubborn_stream(cancellation_token: token)

    token.cancel
    cleanup_started.pop

    assert runner.join(1), "stream consumer did not finish after its shutdown timeout"
    assert_instance_of LittleGhost::Support::InterruptibleStream::CleanupError, runner.value
    assert worker.alive?, "stubborn producer unexpectedly stopped before being released"
  ensure
    release << true if release && worker&.alive?
    worker&.join(1)
    runner&.kill
    runner&.join
  end

  def test_deadline_fails_when_the_producer_does_not_quiesce
    token = LittleGhost::Support::CancellationToken.new
    runner, worker, cleanup_started, release = stubborn_stream(
      cancellation_token: token,
      deadline: Time.now + 0.05
    )

    cleanup_started.pop

    assert runner.join(1), "stream consumer did not finish after its shutdown timeout"
    assert_instance_of LittleGhost::Support::InterruptibleStream::CleanupError, runner.value
    assert worker.alive?, "stubborn producer unexpectedly stopped before being released"
  ensure
    token&.cancel
    release << true if release && worker&.alive?
    worker&.join(1)
    runner&.kill
    runner&.join
  end

  private

  def stubborn_stream(cancellation_token:, deadline: nil)
    producer_started = Queue.new
    cleanup_started = Queue.new
    release = Queue.new
    stream = LittleGhost::Support::InterruptibleStream.new(cancellation_token:, deadline:) do
      producer_started << Thread.current
      Queue.new.pop
    ensure
      cleanup_started << true
      release.pop
    end
    runner = Thread.new do
      stream.to_a
    rescue => error
      error
    end
    runner.report_on_exception = false

    [runner, producer_started.pop, cleanup_started, release]
  end
end
