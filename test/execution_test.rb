# frozen_string_literal: true

require "test_helper"

class ExecutionTest < Minitest::Test
  class ControlledRun < LittleGhost::Run
    attr_reader :cancellation_token, :interruptions, :started, :close_count

    def initialize(events: [], release: nil, interrupt_release: nil)
      @events = events
      @release = release
      @interrupt_release = interrupt_release
      @cancellation_token = LittleGhost::Support::CancellationToken.new
      @interruptions = []
      @started = Queue.new
      @close_count = 0
    end

    def each
      started << true
      @release&.pop
      @events.each { |event| yield event }
      self
    ensure
      @close_count += 1
    end

    def prepare_interruption(payload)
      payload.merge(message: "prepared: #{payload.fetch(:message)}")
    end

    def interrupt_response_with
      message, options = yield
      interrupt_response(message, **options)
    end

    def interrupt_response(message, **options)
      interruptions << [message, options]
      @interrupt_release&.pop
      "accepted"
    end
  end

  def test_runs_in_captured_execution_state_and_reports_completion
    observed = Queue.new
    event = LittleGhost::StreamEvent.build(:text_delta, text: "hello")
    run = ControlledRun.new(events: [event])

    execution = LittleGhost::ExecutionState.with(request_id: "request-1") do
      LittleGhost::Execution.start(run) do |delivered|
        observed << [delivered, LittleGhost::ExecutionState[:request_id]]
      end
    end

    assert_same run, execution.wait(deadline: Time.now + 1)
    assert_equal [event, "request-1"], observed.pop
    assert_equal :finished, execution.state
    assert_predicate execution, :finished?
    refute_predicate execution, :active?
    assert_equal 1, run.close_count
  end

  def test_agent_start_execution_builds_and_supervises_the_run
    run = ControlledRun.new
    agent = LittleGhost::Agent.allocate
    agent.instance_variable_set(:@standalone, true)
    payload = {message: "investigate"}
    received_payloads = Queue.new
    agent.define_singleton_method(:build_run) do |received|
      received_payloads << received
      run
    end

    execution = agent.start_execution(payload)

    assert_instance_of LittleGhost::Execution, execution
    assert_equal payload, received_payloads.pop
    assert_same run, execution.wait(deadline: Time.now + 1)
  end

  def test_wait_re_raises_event_consumer_failures
    error = RuntimeError.new("delivery failed")
    run = ControlledRun.new(events: [LittleGhost::StreamEvent.build(:message_start)])
    execution = LittleGhost::Execution.start(run) { raise error }

    raised = assert_raises(RuntimeError) { execution.wait(deadline: Time.now + 1) }

    assert_same error, raised
    assert_same error, execution.error
    assert_predicate execution, :finished?
  end

  def test_wait_deadline_does_not_cancel_active_run
    release = Queue.new
    run = ControlledRun.new(release:)
    execution = LittleGhost::Execution.start(run)
    run.started.pop

    assert_raises(LittleGhost::DeadlineExceededError) do
      execution.wait(deadline: Time.now - 1)
    end
    refute_predicate run.cancellation_token, :cancelled?
    assert_equal 0, run.close_count

    release << true
    assert_same run, execution.wait(deadline: Time.now + 1)
    assert_equal 1, run.close_count
  end

  def test_interruptions_are_prepared_and_close_waits_for_inflight_delivery
    release_run = Queue.new
    release_interrupt = Queue.new
    run = ControlledRun.new(release: release_run, interrupt_release: release_interrupt)
    execution = LittleGhost::Execution.start(run)
    run.started.pop
    interruption = Thread.new do
      execution.interrupt_response(
        {message: "update", interruption_id: "interrupt-1"},
        metadata: {source: "test"}
      )
    end
    wait_until { run.interruptions.any? }

    release_run << true
    assert_raises(LittleGhost::DeadlineExceededError) do
      execution.close(deadline: Time.now + 0.01)
    end
    assert_predicate run.cancellation_token, :cancelled?
    assert_raises(LittleGhost::AgentInterruptError) do
      execution.interrupt_response(message: "too late")
    end

    release_interrupt << true
    assert_equal "accepted", interruption.value
    assert_same run, execution.close(deadline: Time.now + 1)
    assert_equal 1, run.close_count
    assert_equal [
      "prepared: update",
      {interruption_id: "interrupt-1", metadata: {source: "test"}}
    ], run.interruptions.first
  ensure
    release_run << true if execution&.active?
    release_interrupt << true if interruption&.alive?
    interruption&.join
  end

  private

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    until yield
      raise "condition was not reached" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
