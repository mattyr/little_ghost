# frozen_string_literal: true

require "test_helper"
require "little_ghost/subagents/manager"

class SubagentManagerTest < Minitest::Test
  class Gate
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @open = false
    end

    def wait
      @mutex.synchronize { @condition.wait(@mutex) until @open }
    end

    def open
      @mutex.synchronize do
        @open = true
        @condition.broadcast
      end
    end
  end

  class ControlledAgent
    attr_reader :messages, :started

    def initialize(gate: nil, activity: nil)
      @gate = gate
      @activity = activity
      @messages = []
      @started = Queue.new
    end

    def call(message, cancellation_token:)
      @messages << message
      @started << true
      record_activity(1)
      @gate&.wait
      cancellation_token.raise_if_cancelled!
      @messages.join(" | ")
    ensure
      record_activity(-1)
    end

    private

    def record_activity(change)
      return unless @activity

      @activity[:mutex].synchronize do
        @activity[:active] += change
        @activity[:maximum] = [@activity[:maximum], @activity[:active]].max
      end
    end
  end

  class ClosableAgent < ControlledAgent
    attr_reader :closed

    def close = @closed = true
  end

  def test_definition_exposes_agent_metadata
    factory = ->(_id) { ControlledAgent.new }
    definition = definition_for(factory)

    assert_equal "explore", definition.kind
    assert_equal "Explore code", definition.description
    assert_same factory, definition.factory
  end

  def test_sync_spawns_overlap_and_create_fresh_monotonic_identities
    gate = Gate.new
    activity = {active: 0, maximum: 0, mutex: Mutex.new}
    agents = {}
    manager = manager_for(->(id) { agents[id] = ControlledAgent.new(gate: gate, activity: activity) })

    first = Thread.new { manager.spawn(kind: "explore", task: "olympus", mode: "sync") }
    second = Thread.new { manager.spawn(kind: "explore", task: "hermes", mode: "sync") }
    wait_until { activity[:mutex].synchronize { activity[:active] == 2 } }
    gate.open
    results = [first.value, second.value]

    assert_equal %w[explore-1 explore-2], results.map { |result| result[:subagent_id] }.sort
    assert_equal 2, agents.length
    assert_equal 2, activity[:maximum]
  ensure
    manager&.close
  end

  def test_busy_identity_processes_followups_fifo_on_same_agent
    gate = Gate.new
    agents = {}
    manager = manager_for(->(id) { agents[id] = ControlledAgent.new(gate: gate) })
    spawned = manager.spawn(kind: "explore", task: "first", mode: "async")
    id = spawned.dig(:subagent, :subagent_id)
    agents.fetch(id).started.pop

    queued = manager.send_message(subagent_id: id, message: "second", mode: "async")
    assert_equal 1, queued.dig(:subagent, :queued_turns)
    gate.open
    finished = manager.wait(subagent_ids: [id])

    assert_equal "finished", finished[:status]
    assert_equal 2, finished.dig(:subagents, 0, :latest_turn)
    assert_equal "first | second", finished.dig(:subagents, 0, :response)
    assert_equal %w[first second], agents.fetch(id).messages
  ensure
    manager&.close
  end

  def test_close_closes_spawned_agents
    agent = ClosableAgent.new
    manager = manager_for(->(_id) { agent })
    manager.spawn(kind: "explore", task: "inspect", mode: "sync")

    manager.close

    assert agent.closed
  end

  def test_manager_tool_closes_children_before_earlier_parent_tools
    closed = []
    agent = ClosableAgent.new
    agent.define_singleton_method(:close) { closed << :child }
    manager = manager_for(->(_id) { agent })
    parent_tool = LittleGhost::Tool.define(name: "parent", description: "Parent") { "ok" }
    parent_tool.define_method(:close) { closed << :parent_tool }
    parent = LittleGhost::Agent.new(
      model: Object.new,
      tools: [parent_tool, *manager.tools]
    )
    manager.spawn(kind: "explore", task: "inspect", mode: "sync")

    parent.close

    assert_equal %i[child parent_tool], closed
  ensure
    manager&.close
  end

  def test_wait_timeout_is_normal_and_repeatable
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(->(_id) { agent }, wait_timeout: 0.001)
    manager.spawn(kind: "explore", task: "slow", mode: "async")
    agent.started.pop

    working = manager.wait
    gate.open
    finished = manager.wait

    assert_equal "still_working", working[:status]
    assert_equal "running", working.dig(:subagents, 0, :status)
    assert_equal "finished", finished[:status]
    assert_equal "slow", finished.dig(:subagents, 0, :response)
  ensure
    manager&.close
  end

  def test_wait_responds_promptly_to_external_cancellation
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    token = LittleGhost::Support::CancellationToken.new
    manager = manager_for(->(_id) { agent }, cancellation_token: token, wait_timeout: 30)
    manager.spawn(kind: "explore", task: "slow", mode: "async")
    agent.started.pop
    result = Queue.new
    waiter = Thread.new do
      manager.wait
    rescue => error
      result << error
    end
    wait_until { waiter.status == "sleep" }

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    token.cancel
    joined = waiter.join(0.5)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert joined, "wait did not observe cancellation promptly"
    assert_instance_of LittleGhost::CancelledError, result.pop
    assert_operator elapsed, :<, 0.5
  ensure
    gate&.open
    waiter&.join(1)
    manager&.close
  end

  def test_global_turn_concurrency_and_identity_limits
    gate = Gate.new
    activity = {active: 0, maximum: 0, mutex: Mutex.new}
    manager = manager_for(
      ->(_id) { ControlledAgent.new(gate: gate, activity: activity) },
      max_concurrent: 2,
      max_identities: 3
    )
    %w[one two three].each { |task| manager.spawn(kind: "explore", task: task, mode: "async") }
    rejected = manager.spawn(kind: "explore", task: "four", mode: "async")
    wait_until { activity[:mutex].synchronize { activity[:active] == 2 } }

    assert_equal({
      status: "capacity_reached",
      limit: 3,
      message: "This run has reached its subagent identity limit."
    }, rejected)
    assert_equal 2, activity[:maximum]
    assert_equal 3, manager.list[:subagents].length
  ensure
    gate&.open
    manager&.wait
    manager&.close
  end

  def test_factory_failure_frees_capacity_without_reusing_id
    attempts = 0
    manager = manager_for(lambda { |_id|
      attempts += 1
      raise "secret factory detail" if attempts == 1

      ControlledAgent.new
    }, max_identities: 1)

    _out, _err = capture_io do
      @failed = manager.spawn(kind: "explore", task: "first", mode: "sync")
    end
    spawned = manager.spawn(kind: "explore", task: "second", mode: "sync")

    assert_equal "Subagent could not be created.", @failed[:error]
    assert_equal "explore-2", spawned[:subagent_id]
  ensure
    manager&.close
  end

  def test_message_queue_turn_and_response_limits
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(
      ->(_id) { agent },
      max_turns: 2,
      max_queued_turns_per_identity: 1,
      max_message_chars: 5,
      max_response_chars: 3
    )

    oversized = manager.spawn(kind: "explore", task: "123456", mode: "async")
    manager.spawn(kind: "explore", task: "first", mode: "async")
    agent.started.pop
    queued = manager.send_message(subagent_id: "explore-1", message: "two", mode: "async")
    queue_limited = manager.send_message(subagent_id: "explore-1", message: "tri", mode: "async")
    gate.open
    finished = manager.wait
    listed = manager.list
    turn_limited = manager.spawn(kind: "explore", task: "more", mode: "async")

    assert_equal "invalid_request", oversized[:status]
    assert_equal "working", queued[:status]
    assert_equal "capacity_reached", queue_limited[:status]
    assert_equal "fir", finished.dig(:subagents, 0, :response)
    assert finished.dig(:subagents, 0, :response_truncated)
    refute listed.dig(:subagents, 0).key?(:response)
    assert_equal "capacity_reached", turn_limited[:status]
  ensure
    gate&.open
    manager&.close
  end

  def test_sync_followup_waits_for_exact_turn
    manager = manager_for(->(_id) { ControlledAgent.new })
    spawned = manager.spawn(kind: "explore", task: "first", mode: "sync")
    followed_up = manager.send_message(
      subagent_id: spawned[:subagent_id],
      message: "second",
      mode: "sync"
    )

    assert_equal 2, followed_up[:turn]
    assert_equal "first | second", followed_up[:response]
  ensure
    manager&.close
  end

  def test_little_ghost_agent_followup_retains_messages_and_state
    requests = []
    responses = ["first response", "second response"]
    model = Object.new
    model.define_singleton_method(:stream) do |request|
      requests << request
      message = LittleGhost::Message.new(role: :assistant, content: responses.shift)
      response = LittleGhost::ModelResponse.new(
        message: message,
        stop_reason: :end_turn,
        usage: LittleGhost::Usage.new
      )
      [LittleGhost::StreamEvent.build(:message_stop, response: response)].each
    end
    observed_states = []
    agent_class = Class.new(LittleGhost::Agent) do
      system_prompt "Remember the conversation."
      before_invocation do |context:|
        observed_states << context.state.dup
        context.state[:turns] = context.state.fetch(:turns, 0) + 1
      end
    end
    manager = manager_for(->(_id) { agent_class.new(model: model) })

    spawned = manager.spawn(kind: "explore", task: "first", mode: "sync")
    followed_up = manager.send_message(
      subagent_id: spawned[:subagent_id],
      message: "second",
      mode: "sync"
    )

    assert_equal "second response", followed_up[:response]
    assert_equal %i[system user assistant user], requests.last.messages.map(&:role)
    assert_equal(
      ["Remember the conversation.", "first", "first response", "second"],
      requests.last.messages.map(&:text)
    )
    assert_equal [{}, {turns: 1}], observed_states
  ensure
    manager&.close
  end

  def test_extracts_text_from_agent_run_results
    agent = Class.new do
      def call(message, cancellation_token:)
        cancellation_token.raise_if_cancelled!
        response = LittleGhost::Message.new(role: :assistant, content: "response to #{message}")
        LittleGhost::RunResult.new(
          message: response,
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new,
          messages: [response],
          state: {}
        )
      end
    end.new
    manager = manager_for(->(_id) { agent })

    result = manager.spawn(kind: "explore", task: "inspect", mode: "sync")

    assert_equal "response to inspect", result[:response]
  ensure
    manager&.close
  end

  def test_lifecycle_events_exclude_messages_and_survive_observer_failures
    events = []
    observer = lambda do |event|
      events << event
      raise "observer failed"
    end
    manager = manager_for(->(_id) { ControlledAgent.new }, observer: observer)

    result = manager.spawn(kind: "explore", task: "sensitive task text", mode: "sync")

    assert_equal "finished", result[:status]
    assert_equal %w[spawned turn_started turn_finished], events.map { |event| event[:event] }
    assert_equal events[1][:operation_id], events[2][:operation_id]
    refute events[0].key?(:operation_id)
    refute_includes events.inspect, "sensitive task text"
    refute events.any? { |event| event.key?(:response) || event.key?(:message) }
  ensure
    manager&.close
  end

  def test_close_cancels_running_and_queued_turns_cooperatively
    events = []
    agent = Class.new do
      attr_reader :started, :cancelled

      def initialize
        @started = Queue.new
        @cancelled = Queue.new
      end

      def call(_message, cancellation_token:)
        @started << true
        sleep(0.001) until cancellation_token.cancelled?
        @cancelled << true
        cancellation_token.raise_if_cancelled!
      end
    end.new
    manager = manager_for(->(_id) { agent }, observer: ->(event) { events << event })
    manager.spawn(kind: "explore", task: "first", mode: "async")
    agent.started.pop
    manager.send_message(subagent_id: "explore-1", message: "second", mode: "async")

    manager.close
    agent.cancelled.pop
    listed = manager.list

    assert_equal "cancelled", listed.dig(:subagents, 0, :status)
    assert_equal 0, listed.dig(:subagents, 0, :queued_turns)
    started = events.find { |event| event[:event] == "turn_started" }
    cancelled = events.find { |event| event[:event] == "cancelled" }
    assert_equal started.values_at(:turn, :operation_id), cancelled.values_at(:turn, :operation_id)
  end

  def test_close_is_bounded_when_agent_does_not_cooperate
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    token = LittleGhost::Support::CancellationToken.new
    manager = manager_for(
      ->(_id) { agent },
      cancellation_token: token,
      close_timeout: 0
    )
    manager.spawn(kind: "explore", task: "slow", mode: "async")
    agent.started.pop

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(LittleGhost::Subagents::Manager::CleanupError) { manager.close }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.1
    assert token.cancelled?
    assert_equal "cancelled", manager.list.dig(:subagents, 0, :status)
  ensure
    gate&.open
  end

  def test_close_releases_sync_caller_when_agent_does_not_cooperate
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(->(_id) { agent }, close_timeout: 0)
    caller = Thread.new { manager.spawn(kind: "explore", task: "slow", mode: "sync") }
    agent.started.pop

    assert_raises(LittleGhost::Subagents::Manager::CleanupError) { manager.close }
    result = caller.value

    assert_equal "cancelled", result[:status]
    assert_equal "Subagent turn was cancelled.", result[:error]
  ensure
    gate&.open
  end

  def test_sync_turn_propagates_and_retains_cleanup_errors
    cleanup_error = LittleGhost::CleanupError.new("subagent work is still running")
    agent = Object.new
    agent.define_singleton_method(:call) { |_message, cancellation_token:| raise cleanup_error }
    manager = manager_for(->(_id) { agent })

    raised = assert_raises(LittleGhost::CleanupError) do
      manager.spawn(kind: "explore", task: "inspect", mode: "sync")
    end
    close_error = assert_raises(LittleGhost::CleanupError) { manager.close }

    assert_same cleanup_error, raised
    assert_same cleanup_error, close_error
  end

  def test_async_turn_retains_cleanup_errors_until_close
    cleanup_error = LittleGhost::CleanupError.new("subagent work is still running")
    agent = Object.new
    agent.define_singleton_method(:call) { |_message, cancellation_token:| raise cleanup_error }
    manager = manager_for(->(_id) { agent })

    manager.spawn(kind: "explore", task: "inspect", mode: "async")
    wait_until { manager.list.dig(:subagents, 0, :status) == "failed" }

    raised = assert_raises(LittleGhost::CleanupError) { manager.close }

    assert_same cleanup_error, raised
  end

  def test_external_cancellation_revokes_active_and_queued_turns
    token = LittleGhost::Support::CancellationToken.new
    agent = Class.new do
      attr_reader :started

      def initialize
        @started = Queue.new
      end

      def call(_message, cancellation_token:)
        @started << true
        sleep(0.001) until cancellation_token.cancelled?
        cancellation_token.raise_if_cancelled!
      end
    end.new
    manager = manager_for(->(_id) { agent }, cancellation_token: token)
    manager.spawn(kind: "explore", task: "first", mode: "async")
    agent.started.pop
    followup = Thread.new do
      manager.send_message(subagent_id: "explore-1", message: "second", mode: "sync")
    end

    wait_until { manager.list.dig(:subagents, 0, :queued_turns) == 1 }
    token.cancel
    result = followup.value
    finished = manager.wait

    assert_equal "cancelled", result[:status]
    assert_equal "cancelled", finished.dig(:subagents, 0, :status)
    assert_equal 0, finished.dig(:subagents, 0, :queued_turns)
  ensure
    manager&.close
  end

  def test_deadline_is_propagated_to_little_ghost_agents
    deadline = Time.now + 60
    observed = Queue.new
    agent_class = Class.new(LittleGhost::Agent) do
      define_method(:call) do |_message, **options|
        observed << options
        "done"
      end
    end
    manager = manager_for(
      ->(_id) { agent_class.new(model: Object.new) },
      deadline: deadline
    )

    result = manager.spawn(kind: "explore", task: "inspect", mode: "sync")

    assert_equal "finished", result[:status]
    assert_equal deadline, observed.pop.fetch(:deadline)
  ensure
    manager&.close
  end

  def test_sync_wait_stops_at_the_run_deadline
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(
      ->(_id) { agent },
      deadline: Time.now + 0.01,
      close_timeout: 0
    )

    assert_raises(LittleGhost::DeadlineExceededError) do
      manager.spawn(kind: "explore", task: "slow", mode: "sync")
    end
  ensure
    begin
      manager&.close
    rescue LittleGhost::Subagents::Manager::CleanupError
      nil
    end
    gate&.open
  end

  def test_turn_and_queued_failures_are_sanitized
    gate = Gate.new
    started = Queue.new
    failing_agent = Object.new
    failing_agent.define_singleton_method(:call) do |_message, cancellation_token:|
      started << true
      gate.wait
      raise "https://internal.example secret-provider-detail"
    end

    manager = manager_for(->(_id) { failing_agent })
    manager.spawn(kind: "explore", task: "first", mode: "async")
    started.pop
    queued_thread = Thread.new do
      manager.send_message(subagent_id: "explore-1", message: "second", mode: "sync")
    end
    wait_until { manager.list.dig(:subagents, 0, :queued_turns) == 1 }
    gate.open
    _out, _err = capture_io { @failed = manager.wait }
    queued = queued_thread.value

    assert_equal "Subagent turn failed.", @failed.dig(:subagents, 0, :error)
    assert_equal "A previous turn failed; spawn a new identity.", queued[:error]
    refute_includes @failed.inspect, "internal.example"
  ensure
    gate&.open
    manager&.close
  end

  def test_validation_and_selection_errors
    manager = manager_for(->(_id) { ControlledAgent.new })

    assert_raises(LittleGhost::ToolError) { manager.spawn(kind: "missing", task: "x", mode: "sync") }
    assert_raises(LittleGhost::ToolError) { manager.spawn(kind: "explore", task: "x", mode: "later") }
    assert_raises(LittleGhost::ToolError) { manager.wait(subagent_ids: %w[missing]) }

    manager.spawn(kind: "explore", task: "x", mode: "sync")
    assert_raises(LittleGhost::ToolError) { manager.wait(subagent_ids: %w[explore-1 explore-1]) }
  ensure
    manager&.close
  end

  def test_exposes_manager_operations_as_tools
    manager = manager_for(->(_id) { ControlledAgent.new })
    registry = LittleGhost::ToolRegistry.new(manager.tools)

    spawned = JSON.parse(registry.fetch("spawn_subagent").execute({
      "kind" => "explore", "task" => "inspect", "mode" => "sync"
    }).content)
    listed = JSON.parse(registry.fetch("list_subagents").execute({}).content)
    invalid = registry.fetch("wait_for_subagents").execute({"subagent_ids" => ["missing"]})

    assert_equal "finished", spawned.fetch("status")
    assert_equal "explore-1", listed.fetch("subagents").first.fetch("subagent_id")
    assert invalid.error?
    assert_equal "Unknown subagent id: missing", invalid.content
  ensure
    manager&.close
  end

  private

  def definition_for(factory)
    LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: factory
    )
  end

  def manager_for(factory, **options)
    LittleGhost::Subagents::Manager.new([definition_for(factory)], **options)
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
