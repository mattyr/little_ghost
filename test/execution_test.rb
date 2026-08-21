# frozen_string_literal: true

require "test_helper"
require "async"

class ExecutionTest < Minitest::Test
  class ControlledRun < LittleGhost::Run
    attr_reader :cancellation_token, :interjections, :started, :close_count
    attr_accessor :runtime

    def initialize(events: [], release: nil, interject_release: nil)
      @events = events
      @release = release
      @interject_release = interject_release
      @cancellation_token = LittleGhost::Support::CancellationToken.new
      @interjections = []
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

    def prepare_interjection(payload)
      payload.merge(message: "prepared: #{payload.fetch(:message)}")
    end

    def interject_with
      message, options = yield
      interject(message, **options)
    end

    def interject(message, **options)
      interjections << [message, options]
      @interject_release&.pop
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

  def test_interjections_are_prepared_and_close_waits_for_inflight_delivery
    release_run = Queue.new
    release_interject = Queue.new
    run = ControlledRun.new(release: release_run, interject_release: release_interject)
    execution = LittleGhost::Execution.start(run)
    run.started.pop
    interjection = Thread.new do
      execution.interject(
        {message: "update", interjection_id: "interject-1"},
        metadata: {source: "test"}
      )
    end
    wait_until { run.interjections.any? }

    release_run << true
    assert_raises(LittleGhost::DeadlineExceededError) do
      execution.close(deadline: Time.now + 0.01)
    end
    assert_predicate run.cancellation_token, :cancelled?
    assert_raises(LittleGhost::AgentInterjectionError) do
      execution.interject(message: "too late")
    end

    release_interject << true
    assert_equal "accepted", interjection.value
    assert_same run, execution.close(deadline: Time.now + 1)
    assert_equal 1, run.close_count
    assert_equal [
      "prepared: update",
      {interjection_id: "interject-1", metadata: {source: "test"}}
    ], run.interjections.first
  ensure
    release_run << true if execution&.active?
    release_interject << true if interjection&.alive?
    interjection&.join
  end

  def test_uses_the_runtime_scheduler_for_its_worker_task
    event = LittleGhost::StreamEvent.build(:text_delta, text: "hello")
    run = ControlledRun.new(events: [event])
    observed = nil

    Async do
      calling_thread = Thread.current.object_id
      calling_fiber = Fiber.current.object_id
      run.runtime = Data.define(:task_runner).new(
        LittleGhost::Support::TaskRunner.new(backend: :auto)
      )
      execution = LittleGhost::ExecutionState.with(request_id: "request-1") do
        LittleGhost::Execution.start(run) do
          observed = [
            Thread.current.object_id,
            Fiber.current.object_id,
            LittleGhost::Support::Task.current.backend,
            LittleGhost::ExecutionState[:request_id]
          ]
        end
      end

      assert_same run, execution.wait(deadline: Time.now + 1)
      assert_equal calling_thread, observed.fetch(0)
      refute_equal calling_fiber, observed.fetch(1)
      assert_equal :fiber, observed.fetch(2)
      assert_equal "request-1", observed.fetch(3)
    end.wait
  end

  def test_runtime_can_force_a_worker_thread_inside_a_scheduler
    run = ControlledRun.new(events: [LittleGhost::StreamEvent.build(:message_start)])
    observed_thread = nil

    Async do
      calling_thread = Thread.current.object_id
      run.runtime = Data.define(:task_runner).new(
        LittleGhost::Support::TaskRunner.new(backend: :thread)
      )
      execution = LittleGhost::Execution.start(run) do
        observed_thread = Thread.current.object_id
      end

      execution.wait(deadline: Time.now + 1)
      refute_equal calling_thread, observed_thread
    end.wait
  end

  def test_close_from_another_thread_cooperatively_stops_a_fiber_worker
    execution_queue = Queue.new
    run = ControlledRun.new
    run.runtime = Data.define(:task_runner).new(
      LittleGhost::Support::TaskRunner.new(backend: :auto)
    )
    run.define_singleton_method(:each) do
      started << true
      cancellation_token.wait(1)
      self
    end
    scheduler_thread = Thread.new do
      Async do
        execution = LittleGhost::Execution.start(run)
        execution_queue << execution
        execution.wait(deadline: Time.now + 2)
      end.wait
    end
    execution = execution_queue.pop
    run.started.pop

    assert_same run, execution.close(deadline: Time.now + 1)
    assert scheduler_thread.join(1), "scheduler thread did not stop"
    assert_predicate execution, :finished?
  ensure
    execution&.cancel
    scheduler_thread&.join(1)
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
