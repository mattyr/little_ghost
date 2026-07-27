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

  class InterruptibleAgent < ControlledAgent
    attr_reader :interruptions, :interrupt_target

    def initialize(...)
      super
      @interruptions = []
    end

    def interrupt_response(message, cancellation_token:, deadline:, target_operation_id:)
      cancellation_token.raise_if_cancelled!
      raise LittleGhost::DeadlineExceededError, "deadline" if deadline && Time.now >= deadline

      @interruptions << message
      @interrupt_target = target_operation_id
      LittleGhost::AgentInterruptions::Response.new(text: "Still investigating", tool_calls: false)
    end
  end

  class ActivityRelay
    def initialize
      @observers = []
    end

    def subscribe(&observer)
      @observers << observer
    end

    def publish
      @observers.each(&:call)
    end
  end

  class DelegatingAgent < ControlledAgent
    attr_reader :delegation_activity

    def initialize(...)
      super
      @delegation_activity = ActivityRelay.new
    end
  end

  def test_definition_exposes_agent_metadata
    factory = ->(_id) { ControlledAgent.new }
    definition = definition_for(factory)

    assert_equal "explore", definition.kind
    assert_equal "Explore code", definition.description
    assert_same factory, definition.factory
  end

  def test_model_chosen_task_names_form_strict_hierarchical_agent_paths
    manager = LittleGhost::Subagents::Manager.new(
      [definition_for(->(_id) { ControlledAgent.new })],
      parent_agent_path: "/root/investigate_customer"
    )

    first = manager.spawn(
      kind: "explore",
      task_name: "inspect_source",
      task: "inspect",
      mode: "sync"
    )
    duplicate = assert_raises(LittleGhost::ToolError) do
      manager.spawn(
        kind: "explore",
        task_name: "inspect_source",
        task: "inspect again",
        mode: "sync"
      )
    end

    assert_equal "/root/investigate_customer/inspect_source", first.fetch(:subagent_id)
    assert_includes duplicate.message, "already exists"
    assert_includes duplicate.message, "different task_name"
  ensure
    manager&.close
  end

  def test_agent_path_is_reserved_while_its_factory_is_building
    started = Queue.new
    release = Queue.new
    manager = LittleGhost::Subagents::Manager.new([
      definition_for(lambda { |_id|
        started << true
        release.pop
        ControlledAgent.new
      })
    ])
    first = Thread.new do
      manager.spawn(
        kind: "explore",
        task_name: "inspect_source",
        task: "inspect",
        mode: "sync"
      )
    end
    started.pop

    duplicate = assert_raises(LittleGhost::ToolError) do
      manager.spawn(
        kind: "explore",
        task_name: "inspect_source",
        task: "inspect again",
        mode: "sync"
      )
    end

    assert_includes duplicate.message, "already exists"
    release << true
    assert_equal "/root/inspect_source", first.value.fetch(:subagent_id)
  ensure
    release << true if release && first&.alive?
    first&.join(1)
    manager&.close
  end

  def test_agent_factory_must_bind_the_reserved_canonical_path
    agent_class = Class.new(LittleGhost::Agent) do
      system_prompt "Child"
    end
    manager = manager_for(->(_id) { agent_class.new(model: Object.new) })

    _out, _err = capture_io do
      @mismatched_factory = manager.spawn(
        kind: "explore",
        task_name: "inspect_source",
        task: "inspect",
        mode: "sync"
      )
    end

    assert_equal "failed", @mismatched_factory.fetch(:status)
    assert_equal "Subagent could not be created.", @mismatched_factory.fetch(:error)
    assert_empty manager.list.fetch(:subagents)
  ensure
    manager&.close
  end

  def test_sync_spawns_overlap_with_distinct_canonical_paths
    gate = Gate.new
    activity = {active: 0, maximum: 0, mutex: Mutex.new}
    agents = {}
    manager = manager_for(->(id) { agents[id] = ControlledAgent.new(gate: gate, activity: activity) })

    first = Thread.new do
      manager.spawn(kind: "explore", task_name: "olympus", task: "olympus", mode: "sync")
    end
    second = Thread.new do
      manager.spawn(kind: "explore", task_name: "hermes", task: "hermes", mode: "sync")
    end
    wait_until { activity[:mutex].synchronize { activity[:active] == 2 } }
    gate.open
    results = [first.value, second.value]

    assert_equal %w[/root/hermes /root/olympus], results.map { |result| result[:subagent_id] }.sort
    assert_equal 2, agents.length
    assert_equal 2, activity[:maximum]
  ensure
    manager&.close
  end

  def test_busy_identity_processes_followups_fifo_on_same_agent
    gate = Gate.new
    agents = {}
    manager = manager_for(->(id) { agents[id] = ControlledAgent.new(gate: gate) })
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
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
    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

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
    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

    parent.close

    assert_equal %i[child parent_tool], closed
  ensure
    manager&.close
  end

  def test_wait_timeout_is_normal_and_repeatable
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(->(_id) { agent }, wait_timeout: 0.001)
    manager.spawn(kind: "explore", task_name: "explore", task: "slow", mode: "async")
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

  def test_agent_progress_is_normalized_capped_deduplicated_and_exposed_only_in_active_snapshots
    gate = Gate.new
    ready = Queue.new
    events = []
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "inspect", input: {})
    ignored_end_turn = model_response("not progress", stop_reason: :end_turn)
    ignored_without_tool = model_response("also not progress", stop_reason: :tool_use)
    first = model_response(" \tWorking\n\u0000 through\u202E\u200B it  ", stop_reason: :tool_use, tool_use:)
    duplicate = model_response("Working through it", stop_reason: :tool_use, tool_use:)
    unread_text = +"should not be read"
    unread_text.define_singleton_method(:each_char) { raise "later text block was traversed" }
    latest = LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(
        role: :assistant,
        content: ["x" * 161, unread_text, tool_use]
      ),
      stop_reason: :tool_use
    )
    agent = streaming_agent do |stream|
      [ignored_end_turn, ignored_without_tool, first, duplicate, latest].each do |response|
        stream << LittleGhost::StreamEvent.build(:message_stop, response:)
      end
      ready << true
      gate.wait
      stream << LittleGhost::StreamEvent.build(:invocation_stop, result: run_result("done"))
    end
    manager = manager_for(
      ->(_id) { agent },
      observer: ->(event) { events << event },
      max_queued_turns_per_identity: 1,
      wait_timeout: 0.001
    )

    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "async")
    ready.pop
    listed = manager.list.dig(:subagents, 0)
    waited = manager.wait.dig(:subagents, 0)

    assert_equal({message: "x" * 160, sequence: 6}, listed[:progress])
    assert_equal listed[:progress], waited[:progress]
    refute events.any? { |event| event.key?(:progress) || event.key?(:message) }

    queued = manager.send_message(
      subagent_id: "/root/explore",
      message: "follow up",
      mode: "async"
    )
    queue_limited = manager.send_message(
      subagent_id: "/root/explore",
      message: "one more",
      mode: "async"
    )
    refute queued.fetch(:subagent).key?(:progress)
    refute queue_limited.fetch(:subagent).key?(:progress)

    gate.open
    finished = manager.wait.dig(:subagents, 0)

    refute finished.key?(:progress)
  ensure
    gate&.open
    manager&.close
  end

  def test_agent_progress_sequence_remains_monotonic_across_manager_turns
    gates = [Gate.new, Gate.new]
    ready = Queue.new
    turn = 0
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "inspect", input: {})
    agent = streaming_agent do |stream|
      current_turn = turn
      turn += 1
      stream << LittleGhost::StreamEvent.build(
        :message_stop,
        response: model_response("same progress", stop_reason: :tool_use, tool_use:)
      )
      ready << true
      gates.fetch(current_turn).wait
      stream << LittleGhost::StreamEvent.build(
        :invocation_stop,
        result: run_result("turn #{current_turn + 1}")
      )
    end
    manager = manager_for(->(_id) { agent })

    manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
    ready.pop
    assert_equal 2, manager.list.dig(:subagents, 0, :progress, :sequence)
    gates.fetch(0).open
    manager.wait
    refute manager.list.dig(:subagents, 0).key?(:progress)

    manager.send_message(subagent_id: "/root/explore", message: "second", mode: "async")
    ready.pop
    assert_equal(
      {message: "same progress", sequence: 5},
      manager.list.dig(:subagents, 0, :progress)
    )
    gates.fetch(1).open
    manager.wait
  ensure
    gates&.each(&:open)
    manager&.close
  end

  def test_nested_delegation_activity_advances_the_existing_progress_sequence
    gate = Gate.new
    agent = DelegatingAgent.new(gate:)
    manager = manager_for(->(_id) { agent })

    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "async")
    agent.started.pop
    assert_equal({sequence: 1}, manager.list.dig(:subagents, 0, :progress))

    agent.delegation_activity.publish
    agent.delegation_activity.publish

    assert_equal({sequence: 3}, manager.list.dig(:subagents, 0, :progress))
  ensure
    gate&.open
    manager&.close
  end

  def test_agent_progress_is_cleared_when_a_turn_fails
    ready = Queue.new
    gate = Gate.new
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "inspect", input: {})
    agent = streaming_agent do |stream|
      stream << LittleGhost::StreamEvent.build(
        :message_stop,
        response: model_response("working", stop_reason: :tool_use, tool_use:)
      )
      ready << true
      gate.wait
      raise "failed"
    end
    manager = manager_for(->(_id) { agent })

    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "async")
    ready.pop
    assert manager.list.dig(:subagents, 0).key?(:progress)
    gate.open
    _out, _err = capture_io { @failed_progress_turn = manager.wait }

    failed = @failed_progress_turn.dig(:subagents, 0)
    assert_equal "failed", failed[:status]
    refute failed.key?(:progress)
  ensure
    gate&.open
    manager&.close
  end

  def test_wait_responds_promptly_to_external_cancellation
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    token = LittleGhost::Support::CancellationToken.new
    manager = manager_for(->(_id) { agent }, cancellation_token: token, wait_timeout: 30)
    manager.spawn(kind: "explore", task_name: "explore", task: "slow", mode: "async")
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
    %w[one two three].each do |task|
      manager.spawn(kind: "explore", task_name: task, task:, mode: "async")
    end
    rejected = manager.spawn(kind: "explore", task_name: "four", task: "four", mode: "async")
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

  def test_factory_failure_frees_capacity_and_path
    attempts = 0
    events = []
    manager = manager_for(lambda { |_id|
      attempts += 1
      raise "secret factory detail" if attempts == 1

      ControlledAgent.new
    }, max_identities: 1, observer: ->(event) { events << event })

    _out, _err = capture_io do
      @failed = manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "sync")
    end
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "second", mode: "sync")

    assert_equal "Subagent could not be created.", @failed[:error]
    assert_equal "/root/explore", spawned[:subagent_id]
    assert_equal({
      event: "factory_failed",
      subagent_id: "/root/explore",
      kind: "explore",
      status: "failed",
      error_type: "RuntimeError"
    }, events.fetch(0))
    refute_includes events.inspect, "secret factory detail"
    refute_includes events.inspect, "first"
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

    oversized = manager.spawn(kind: "explore", task_name: "explore", task: "123456", mode: "async")
    manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
    agent.started.pop
    queued = manager.send_message(subagent_id: "/root/explore", message: "two", mode: "async")
    queue_limited = manager.send_message(subagent_id: "/root/explore", message: "tri", mode: "async")
    gate.open
    finished = manager.wait
    listed = manager.list
    turn_limited = manager.spawn(kind: "explore", task_name: "explore", task: "more", mode: "async")

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
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "sync")
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
    manager = manager_for(->(id) { agent_class.new(model: model, agent_path: id) })

    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "sync")
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

  def test_durable_conversation_restores_across_managers_with_compact_session_history
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    requests = []
    responses = ["first response", "second response"]
    factory = lambda do |id|
      model = Object.new
      model.define_singleton_method(:stream) do |request|
        requests << request
        response = LittleGhost::ModelResponse.new(
          message: LittleGhost::Message.new(role: :assistant, content: responses.shift),
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new
        )
        [LittleGhost::StreamEvent.build(:message_stop, response:)].each
      end
      LittleGhost::Agent.new(model:, agent_path: id)
    end
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory:
    )
    first_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    spawned = first_manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")
    subagent_id = spawned.fetch(:subagent_id)
    conversation_id = first_manager.list.dig(:subagents, 0, :conversation_id)
    first_manager.close

    restored_parent = LittleGhost::Session.new(id: "parent", store:)
    second_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: restored_parent)
    listed = second_manager.list.fetch(:subagents).first
    followed_up = second_manager.send_message(
      subagent_id:,
      message: "go deeper",
      mode: "sync"
    )
    child = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.conversation_session_id(conversation_id),
      store:
    )
    registry_record = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.registry_session_id(restored_parent),
      store:
    ).state
      .fetch("conversations")
      .fetch(subagent_id)

    assert_equal "/root/explore", subagent_id
    assert_equal true, listed.fetch(:resumed)
    assert_equal conversation_id, listed.fetch(:conversation_id)
    assert_equal 2, followed_up.fetch(:turn)
    assert_equal %i[user assistant user], requests.last.messages.map(&:role)
    assert_equal(
      ["first response", "second response"],
      child.history.select { |message| message.role == :assistant }.map(&:text)
    )
    assert_equal %i[user assistant user assistant], child.history.map(&:role)
    assert_equal(
      %w[commit_id commit_slot conversation_id kind latest_turn message_count updated_at],
      registry_record.keys.sort
    )
  ensure
    first_manager&.close
    second_manager&.close
  end

  def test_structured_result_is_serialized_in_restored_history
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    restored_history = []
    restored_state = {}
    builds = 0
    structured_message = LittleGhost::Message.new(role: :assistant, content: [])
    structured_result = LittleGhost::RunResult.new(
      message: structured_message,
      stop_reason: :structured_result,
      usage: LittleGhost::Usage.new,
      messages: [structured_message],
      state: {step: 1},
      structured_result: LittleGhost::StructuredResult.new(
        schema_name: "evidence",
        value: {"claim" => "supported"}
      )
    )
    resumed_result = run_result("resumed")
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: lambda do |id|
        builds += 1
        agent = LittleGhost::Agent.new(model: Object.new, agent_path: id)
        agent.define_singleton_method(:stream) do |_message, **options|
          Enumerator.new do |events|
            if builds == 1
              events << LittleGhost::StreamEvent.build(:invocation_stop, result: structured_result)
            else
              restored_history.concat(options.fetch(:history))
              restored_state.merge!(options.fetch(:context))
              events << LittleGhost::StreamEvent.build(:invocation_stop, result: resumed_result)
            end
          end
        end
        agent
      end
    )
    first_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    first = first_manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")
    first_manager.close

    second_manager = LittleGhost::Subagents::Manager.new(
      [definition],
      parent_session: LittleGhost::Session.new(id: "parent", store:)
    )
    second_manager.send_message(
      subagent_id: first.fetch(:subagent_id),
      message: "continue",
      mode: "sync"
    )

    assert_equal "{\"claim\":\"supported\"}", restored_history.fetch(1).text
    assert_equal({step: 1}, restored_state)
  ensure
    first_manager&.close
    second_manager&.close
  end

  def test_child_tools_receive_stable_distinct_conversation_ids_across_restore
    observed = []
    tool_class = LittleGhost::Tool.define(
      name: "observe_conversation",
      description: "Observe conversation"
    ) do |_input, context:|
      observed << context.conversation_id
      "observed"
    end
    factory = lambda do |id|
      calls = 0
      model = Object.new
      model.define_singleton_method(:stream) do |_request|
        calls += 1
        message = if calls.odd?
          LittleGhost::Message.new(
            role: :assistant,
            content: LittleGhost::Content::ToolUse.new(
              id: "observe-#{calls}",
              name: "observe_conversation",
              input: {}
            )
          )
        else
          LittleGhost::Message.new(role: :assistant, content: "done")
        end
        response = LittleGhost::ModelResponse.new(
          message:,
          stop_reason: calls.odd? ? :tool_use : :end_turn,
          usage: LittleGhost::Usage.new
        )
        [LittleGhost::StreamEvent.build(:message_stop, response:)].each
      end
      LittleGhost::Agent.new(model:, tools: [tool_class.new], agent_path: id)
    end
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory:
    )
    first_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    first = first_manager.spawn(kind: "explore", task_name: "first", task: "first", mode: "sync")
    first_id = first.fetch(:subagent_id)
    first_conversation_id = first_manager.list.dig(:subagents, 0, :conversation_id)
    first_manager.send_message(subagent_id: first_id, message: "follow up", mode: "sync")
    second = first_manager.spawn(kind: "explore", task_name: "second", task: "second", mode: "sync")
    second_conversation_id = first_manager.list.fetch(:subagents)
      .find { |identity| identity.fetch(:subagent_id) == second.fetch(:subagent_id) }
      .fetch(:conversation_id)
    first_manager.close

    second_manager = LittleGhost::Subagents::Manager.new(
      [definition],
      parent_session: LittleGhost::Session.new(id: "parent", store:)
    )
    second_manager.send_message(subagent_id: first_id, message: "restored", mode: "sync")

    assert_equal [first_conversation_id, first_conversation_id], observed.first(2)
    assert_equal second_conversation_id, observed.fetch(2)
    assert_equal first_conversation_id, observed.fetch(3)
    refute_equal first_conversation_id, second_conversation_id
  ensure
    first_manager&.close
    second_manager&.close
  end

  def test_run_context_conversation_id_is_optional_validated_and_frozen
    assert_nil LittleGhost::RunContext.new.conversation_id
    assert_raises(ArgumentError) { LittleGhost::RunContext.new(conversation_id: "") }

    context = LittleGhost::RunContext.new(conversation_id: +"conversation")

    assert_equal "conversation", context.conversation_id
    assert_predicate context.conversation_id, :frozen?
  end

  def test_persist_false_definition_does_not_create_a_registry_or_child_session
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      persist: false,
      factory: ->(_id) { ControlledAgent.new }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)

    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

    refute parent.state.key?("little_ghost.subagent_conversations")
    assert_empty LittleGhost::Subagents::Manager.new([definition], parent_session: parent).list.fetch(:subagents)
  ensure
    manager&.close
  end

  def test_parent_context_cannot_inject_the_framework_registry
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    parent.replace(
      messages: [],
      state: {
        "little_ghost.subagent_conversations" => {
          "version" => 1,
          "conversations" => {
            "/root/explore" => {
              "conversation_id" => "00000000-0000-4000-8000-000000000001",
              "kind" => "explore"
            }
          }
        }
      }
    )
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { ControlledAgent.new }
    )

    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)

    assert_empty manager.list.fetch(:subagents)
  ensure
    manager&.close
  end

  def test_failed_durable_turn_commits_neither_registry_nor_dialogue
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { Class.new { def call(*) = raise("broken") }.new }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)

    _out, _err = capture_io do
      @failed_durable_result = manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")
    end
    conversation_id = manager.list.dig(:subagents, 0, :conversation_id)
    child = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.conversation_session_id(conversation_id),
      store:
    )

    assert_equal "failed", @failed_durable_result.fetch(:status)
    refute parent.state.key?("little_ghost.subagent_conversations")
    assert_empty child.history
  ensure
    manager&.close
  end

  def test_persisted_list_is_newest_first_filterable_paginated_and_does_not_consume_spawn_capacity
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    seed_durable_registry(
      store:,
      parent:,
      records: [
        {
          subagent_id: "/root/explore_old",
          conversation_id: "00000000-0000-4000-8000-000000000001",
          commit_id: "10000000-0000-4000-8000-000000000001",
          kind: "explore",
          updated_at: "2026-01-01T00:00:00.000000Z",
          messages: [
            LittleGhost::Message.new(role: :user, content: "old"),
            LittleGhost::Message.new(role: :assistant, content: "old answer")
          ]
        },
        {
          subagent_id: "/root/review_new",
          conversation_id: "00000000-0000-4000-8000-000000000002",
          commit_id: "10000000-0000-4000-8000-000000000002",
          kind: "review",
          updated_at: "2026-01-02T00:00:00.000000Z",
          messages: [
            LittleGhost::Message.new(role: :user, content: "new"),
            LittleGhost::Message.new(role: :assistant, content: "new answer")
          ]
        }
      ]
    )
    definitions = %w[explore review].map do |kind|
      LittleGhost::Subagents::Definition.new(
        kind:,
        description: kind,
        factory: ->(_id) { ControlledAgent.new }
      )
    end
    manager = LittleGhost::Subagents::Manager.new(
      definitions,
      parent_session: parent,
      max_identities: 2
    )

    first_page = manager.list(limit: 1)
    second_page = manager.list(limit: 1, cursor: first_page.fetch(:next_cursor))
    filtered = manager.list(kind: "explore")
    spawned = manager.spawn(kind: "explore", task_name: "explore_new", task: "new work", mode: "sync")

    assert_equal ["/root/review_new"],
      first_page.fetch(:subagents).map { |value| value.fetch(:subagent_id) }
    assert_equal ["/root/explore_old"],
      second_page.fetch(:subagents).map { |value| value.fetch(:subagent_id) }
    refute second_page.key?(:next_cursor)
    assert_equal ["/root/explore_old"],
      filtered.fetch(:subagents).map { |value| value.fetch(:subagent_id) }
    assert_equal "/root/explore_new", spawned.fetch(:subagent_id)
  ensure
    manager&.close
  end

  def test_persisted_child_session_is_loaded_only_on_first_followup
    store_class = Class.new(LittleGhost::SessionStores::Memory) do
      attr_reader :loads

      def initialize
        super
        @loads = []
      end

      def load(id, actor_id: nil)
        @loads << id.to_s
        super
      end
    end
    store = store_class.new
    conversation_id = "00000000-0000-4000-8000-000000000001"
    parent = LittleGhost::Session.new(id: "parent", store:)
    messages = [
      LittleGhost::Message.new(role: :user, content: "initial"),
      LittleGhost::Message.new(role: :assistant, content: "answer")
    ]
    seed_durable_registry(
      store:,
      parent:,
      records: [{
        subagent_id: "/root/explore_one",
        conversation_id:,
        commit_id: "10000000-0000-4000-8000-000000000001",
        kind: "explore",
        updated_at: "2026-01-01T00:00:00.000000Z",
        messages:
      }]
    )
    store.loads.clear
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { ControlledAgent.new }
    )

    manager = LittleGhost::Subagents::Manager.new(
      [definition],
      parent_session: parent
    )
    manager.list

    registry_id = LittleGhost::Subagents::Manager.registry_session_id(parent)
    child_id = LittleGhost::Subagents::Manager.conversation_session_id(conversation_id)
    commit_id = LittleGhost::Subagents::Manager.commit_session_id(conversation_id, 0)
    assert_equal [registry_id], store.loads

    manager.send_message(
      subagent_id: "/root/explore_one",
      message: "continue",
      mode: "sync"
    )

    assert_equal 1, store.loads.count(child_id)
    assert_equal 1, store.loads.count(commit_id)
  ensure
    manager&.close
  end

  def test_registry_failure_leaves_child_suffix_invisible_and_restore_repairs_it
    store_class = Class.new(LittleGhost::SessionStores::Memory) do
      attr_accessor :fail_id

      def replace(id, **)
        if id.to_s == fail_id
          self.fail_id = nil
          raise "injected registry failure"
        end
        super
      end
    end
    store = store_class.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    fail_factory = false
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: lambda do |_id|
        raise "factory unavailable" if fail_factory

        ControlledAgent.new
      end
    )
    first_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    first = first_manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "sync")
    subagent_id = first.fetch(:subagent_id)
    conversation_id = first_manager.list.dig(:subagents, 0, :conversation_id)
    store.fail_id = LittleGhost::Subagents::Manager.registry_session_id(parent)

    _out, _err = capture_io do
      @registry_failed = first_manager.send_message(
        subagent_id:,
        message: "uncommitted",
        mode: "sync"
      )
    end
    first_manager.close
    child_id = LittleGhost::Subagents::Manager.conversation_session_id(conversation_id)
    assert_equal 4, LittleGhost::Session.new(id: child_id, store:).history.length

    fail_factory = true
    restored_parent = LittleGhost::Session.new(id: "parent", store:)
    second_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: restored_parent)
    assert_equal 1, second_manager.list.dig(:subagents, 0, :latest_turn)
    _out, _err = capture_io do
      assert_raises(LittleGhost::ToolError) do
        second_manager.send_message(subagent_id:, message: "retry", mode: "sync")
      end
    end

    assert_equal "failed", @registry_failed.fetch(:status)
    assert_equal ["first", "first"],
      LittleGhost::Session.new(id: child_id, store:).history.map(&:text)
  ensure
    first_manager&.close
    second_manager&.close
  end

  def test_child_persistence_failure_never_advances_the_registry
    store_class = Class.new(LittleGhost::SessionStores::Memory) do
      def append(id, **)
        raise "injected child failure" if id.to_s.start_with?("lg_subagent_conversation_")

        super
      end
    end
    store = store_class.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { ControlledAgent.new }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)

    _out, _err = capture_io do
      @child_failed = manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "sync")
    end
    restored = LittleGhost::Subagents::Manager.new(
      [definition],
      parent_session: LittleGhost::Session.new(id: "parent", store:)
    )

    assert_equal "failed", @child_failed.fetch(:status)
    assert_empty restored.list.fetch(:subagents)
  ensure
    manager&.close
    restored&.close
  end

  def test_restore_rejects_untrusted_registry_ids_metadata_and_persist_false_records
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    valid = {
      subagent_id: "/root/explore_one",
      conversation_id: "00000000-0000-4000-8000-000000000001",
      commit_id: "10000000-0000-4000-8000-000000000001",
      kind: "explore",
      updated_at: "2026-01-01T00:00:00.000000Z",
      messages: [
        LittleGhost::Message.new(role: :user, content: "initial"),
        LittleGhost::Message.new(role: :assistant, content: "answer")
      ]
    }
    seed_durable_registry(store:, parent:, records: [valid])
    registry_metadata = {
      "little_ghost_kind" => "subagent_registry",
      "little_ghost_parent_link" => LittleGhost::Subagents::Manager.parent_link(parent)
    }
    registry = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.registry_session_id(parent),
      store:,
      metadata: registry_metadata
    )
    registry_state = registry.state
    valid_record = registry_state.fetch("conversations").fetch(valid.fetch(:subagent_id))
    registry_state.fetch("conversations")["invalid-id"] = valid_record
    registry_state.fetch("conversations")["/root/explore_two"] =
      valid_record.merge("conversation_id" => "not-a-uuid")
    registry_state.fetch("conversations")["/root/explore_one/nested"] = valid_record
    registry.replace(messages: [], state: registry_state, metadata: registry_metadata)
    child_id = LittleGhost::Subagents::Manager.conversation_session_id(valid.fetch(:conversation_id))
    wrong_metadata = {
      "little_ghost_kind" => "subagent_conversation",
      "little_ghost_parent_link" => "wrong",
      "little_ghost_conversation_id" => valid.fetch(:conversation_id)
    }
    LittleGhost::Session.new(id: child_id, store:).replace(
      messages: valid.fetch(:messages),
      metadata: wrong_metadata
    )
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { ControlledAgent.new }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    assert_equal [valid.fetch(:subagent_id)],
      manager.list.fetch(:subagents).map { |record| record.fetch(:subagent_id) }

    _out, _err = capture_io do
      assert_raises(LittleGhost::ToolError) do
        manager.send_message(
          subagent_id: valid.fetch(:subagent_id),
          message: "continue",
          mode: "sync"
        )
      end
    end

    transient_definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      persist: false,
      factory: ->(_id) { ControlledAgent.new }
    )
    transient_manager = LittleGhost::Subagents::Manager.new(
      [transient_definition],
      parent_session: LittleGhost::Session.new(id: "parent", store:)
    )
    assert_empty transient_manager.list.fetch(:subagents)
  ensure
    manager&.close
    transient_manager&.close
  end

  def test_list_cursor_and_interrupt_aggregate_limits_are_bounded
    gate = Gate.new
    agent = InterruptibleAgent.new(gate:)
    manager = manager_for(
      ->(_id) { agent },
      max_queued_turns_per_identity: 1,
      max_message_chars: 5
    )
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "work", mode: "async")
    subagent_id = spawned.dig(:subagent, :subagent_id)
    agent.started.pop

    manager.interrupt(subagent_id:, message: "12345")

    assert_raises(LittleGhost::ToolError) { manager.interrupt(subagent_id:, message: "x") }
    assert_raises(LittleGhost::ToolError) { manager.list(cursor: "x" * 513) }
  ensure
    gate&.open
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

    result = manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

    assert_equal "response to inspect", result[:response]
  ensure
    manager&.close
  end

  def test_propagates_structured_results_from_agent_run_results
    agent = Class.new do
      def call(_message, cancellation_token:)
        cancellation_token.raise_if_cancelled!
        response = LittleGhost::Message.new(role: :assistant, content: [])
        LittleGhost::RunResult.new(
          message: response,
          stop_reason: :structured_result,
          usage: LittleGhost::Usage.new,
          messages: [response],
          state: {},
          structured_result: LittleGhost::StructuredResult.new(
            schema_name: "evidence",
            value: {"claim" => "supported"}
          )
        )
      end
    end.new
    manager = manager_for(->(_id) { agent })

    result = manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

    assert_equal({"claim" => "supported"}, result[:response])
  ensure
    manager&.close
  end

  def test_rejects_oversized_structured_results_without_corrupting_their_type
    agent = Class.new do
      def call(_message, cancellation_token:)
        cancellation_token.raise_if_cancelled!
        response = LittleGhost::Message.new(role: :assistant, content: [])
        LittleGhost::RunResult.new(
          message: response,
          stop_reason: :structured_result,
          usage: LittleGhost::Usage.new,
          messages: [response],
          state: {},
          structured_result: LittleGhost::StructuredResult.new(
            schema_name: "evidence",
            value: {"claim" => "too large"}
          )
        )
      end
    end.new
    manager = manager_for(->(_id) { agent }, max_response_chars: 5)

    _out, _err = capture_io do
      @result = manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")
    end

    assert_equal "failed", @result[:status]
    assert_equal "Subagent turn failed.", @result[:error]
    refute @result.key?(:response)
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

    result = manager.spawn(kind: "explore", task_name: "explore", task: "sensitive task text", mode: "sync")

    assert_equal "finished", result[:status]
    assert_equal %w[spawned turn_started turn_finished], events.map { |event| event[:event] }
    assert_equal events[0][:operation_id], events[1][:operation_id]
    assert_equal events[1][:operation_id], events[2][:operation_id]
    refute_includes events.inspect, "sensitive task text"
    refute events.any? { |event| event.key?(:response) || event.key?(:message) }
  ensure
    manager&.close
  end

  def test_tool_context_identifies_the_agent_that_queued_each_turn
    events = []
    manager = manager_for(
      ->(_id) { ControlledAgent.new },
      observer: ->(event) { events << event }
    )
    registry = LittleGhost::ToolRegistry.new(manager.tools)
    first_context = LittleGhost::RunContext.new
    first_context.bind_agent_operation_id("investigator-agent")
    second_context = LittleGhost::RunContext.new
    second_context.bind_agent_operation_id("main-agent")

    registry.fetch("spawn_subagent").execute(
      {"kind" => "explore", "task_name" => "inspect", "task" => "inspect", "mode" => "sync"},
      context: first_context
    )
    registry.fetch("send_message_to_subagent").execute(
      {"subagent_id" => "/root/inspect", "message" => "summarize", "mode" => "sync"},
      context: second_context
    )

    turns = events.select { |event| event[:event] == "turn_started" }
    finishes = events.select { |event| event[:event] == "turn_finished" }
    queued = events.select { |event| %w[spawned message_queued].include?(event[:event]) }
    assert_equal %w[investigator-agent main-agent], queued.map { |event| event[:parent_operation_id] }
    assert_equal queued.map { |event| event[:operation_id] }, turns.map { |event| event[:operation_id] }
    assert_equal %w[investigator-agent main-agent], turns.map { |event| event[:parent_operation_id] }
    assert_equal turns.map { |event| event[:operation_id] }, finishes.map { |event| event[:operation_id] }
    assert_equal turns.map { |event| event[:parent_operation_id] },
      finishes.map { |event| event[:parent_operation_id] }
  ensure
    manager&.close
  end

  def test_capacity_delayed_turn_keeps_its_enqueue_operation_and_parent
    gates = {"/root/explore" => Gate.new, "/root/explore_second" => Gate.new}
    agents = {}
    events = []
    manager = manager_for(
      ->(id) { agents[id] = ControlledAgent.new(gate: gates.fetch(id)) },
      max_concurrent: 1,
      observer: ->(event) { events << event }
    )

    manager.spawn(
      kind: "explore",
      task_name: "explore",
      task: "first",
      mode: "async",
      parent_operation_id: "first-caller"
    )
    agents.fetch("/root/explore").started.pop
    manager.spawn(
      kind: "explore",
      task_name: "explore_second",
      task: "second",
      mode: "async",
      parent_operation_id: "caller-that-finishes-while-queued"
    )
    queued = events.find { |event| event[:event] == "spawned" && event[:subagent_id] == "/root/explore_second" }
    refute_nil queued
    refute events.any? { |event| event[:event] == "turn_started" && event[:subagent_id] == "/root/explore_second" }

    gates.fetch("/root/explore").open
    agents.fetch("/root/explore_second").started.pop
    started = events.find { |event| event[:event] == "turn_started" && event[:subagent_id] == "/root/explore_second" }

    assert_equal queued[:operation_id], started[:operation_id]
    assert_equal "caller-that-finishes-while-queued", queued[:parent_operation_id]
    assert_equal queued[:parent_operation_id], started[:parent_operation_id]
  ensure
    gates&.each_value(&:open)
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
    manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
    agent.started.pop
    manager.send_message(subagent_id: "/root/explore", message: "second", mode: "async")

    manager.close
    agent.cancelled.pop
    listed = manager.list

    assert_equal "cancelled", listed.dig(:subagents, 0, :status)
    assert_equal 0, listed.dig(:subagents, 0, :queued_turns)
    started = events.find { |event| event[:event] == "turn_started" }
    cancelled = events.find do |event|
      event[:event] == "cancelled" && event[:operation_id] == started[:operation_id]
    end
    assert_equal started.values_at(:turn, :operation_id), cancelled.values_at(:turn, :operation_id)
    queued_operations = events.filter_map do |event|
      event[:operation_id] if %w[spawned message_queued].include?(event[:event])
    end
    cancelled_operations = events.filter_map do |event|
      event[:operation_id] if event[:event] == "cancelled"
    end
    assert_equal queued_operations.sort, cancelled_operations.sort
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
    manager.spawn(kind: "explore", task_name: "explore", task: "slow", mode: "async")
    agent.started.pop

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(LittleGhost::Subagents::Manager::CleanupError) { manager.close }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.1
    refute token.cancelled?
    assert_equal "cancelled", manager.list.dig(:subagents, 0, :status)
  ensure
    gate&.open
  end

  def test_close_releases_sync_caller_when_agent_does_not_cooperate
    gate = Gate.new
    agent = ControlledAgent.new(gate: gate)
    manager = manager_for(->(_id) { agent }, close_timeout: 0)
    caller = Thread.new { manager.spawn(kind: "explore", task_name: "explore", task: "slow", mode: "sync") }
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
      manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")
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

    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "async")
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
    manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
    agent.started.pop
    followup = Thread.new do
      manager.send_message(subagent_id: "/root/explore", message: "second", mode: "sync")
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
      define_method(:stream) do |_message, **options|
        observed << options
        message = LittleGhost::Message.new(role: :assistant, content: "done")
        result = LittleGhost::RunResult.new(
          message:,
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new,
          messages: [message],
          state: {}
        )
        [LittleGhost::StreamEvent.build(
          :invocation_stop,
          result:
        )].each
      end
    end
    manager = manager_for(
      ->(id) { agent_class.new(model: Object.new, agent_path: id) },
      deadline: deadline
    )

    result = manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "sync")

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
      manager.spawn(kind: "explore", task_name: "explore", task: "slow", mode: "sync")
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

    events = []
    manager = manager_for(->(_id) { failing_agent }, observer: ->(event) { events << event })
    manager.spawn(kind: "explore", task_name: "explore", task: "first", mode: "async")
    started.pop
    queued_thread = Thread.new do
      manager.send_message(subagent_id: "/root/explore", message: "second", mode: "sync")
    end
    wait_until { manager.list.dig(:subagents, 0, :queued_turns) == 1 }
    gate.open
    _out, _err = capture_io { @failed = manager.wait }
    queued = queued_thread.value

    assert_equal "Subagent turn failed.", @failed.dig(:subagents, 0, :error)
    assert_equal "A previous turn failed; spawn a new identity.", queued[:error]
    refute_includes @failed.inspect, "internal.example"
    queued_operations = events.filter_map do |event|
      event[:operation_id] if %w[spawned message_queued].include?(event[:event])
    end
    failed_operations = events.filter_map do |event|
      event[:operation_id] if event[:event] == "turn_failed"
    end
    assert_equal queued_operations.sort, failed_operations.sort
  ensure
    gate&.open
    manager&.close
  end

  def test_validation_and_selection_errors
    manager = manager_for(->(_id) { ControlledAgent.new })

    assert_raises(LittleGhost::ToolError) { manager.spawn(kind: "missing", task_name: "missing", task: "x", mode: "sync") }
    assert_raises(LittleGhost::ToolError) { manager.spawn(kind: "explore", task_name: "explore", task: "x", mode: "later") }
    assert_raises(LittleGhost::ToolError) do
      manager.spawn(kind: "explore", task_name: "x" * 41, task: "x", mode: "sync")
    end
    assert_raises(LittleGhost::ToolError) { manager.wait(subagent_ids: %w[missing]) }

    manager.spawn(kind: "explore", task_name: "explore", task: "x", mode: "sync")
    assert_raises(LittleGhost::ToolError) { manager.wait(subagent_ids: %w[/root/explore /root/explore]) }
  ensure
    manager&.close
  end

  def test_exposes_manager_operations_as_tools
    manager = manager_for(->(_id) { ControlledAgent.new })
    registry = LittleGhost::ToolRegistry.new(manager.tools)

    spawned = JSON.parse(registry.fetch("spawn_subagent").execute({
      "kind" => "explore", "task_name" => "inspect", "task" => "inspect", "mode" => "sync"
    }).content)
    listed = JSON.parse(registry.fetch("list_subagents").execute({}).content)
    invalid = registry.fetch("wait_for_subagents").execute({"subagent_ids" => ["missing"]})

    assert_equal "finished", spawned.fetch("status")
    assert_equal "/root/inspect", listed.fetch("subagents").first.fetch("subagent_id")
    assert_includes registry.fetch("spawn_subagent").input_schema
      .dig("properties", "kind", "description"), "explore: Explore code"
    assert_equal 40, registry.fetch("spawn_subagent").input_schema
      .dig("properties", "task_name", "maxLength")
    assert invalid.error?
    assert_equal "Unknown subagent id: missing", invalid.content
  ensure
    manager&.close
  end

  def test_interrupt_tool_returns_text_without_queuing_another_turn
    gate = Gate.new
    agent = InterruptibleAgent.new(gate:)
    manager = manager_for(->(_id) { agent })
    registry = LittleGhost::ToolRegistry.new(manager.tools)
    manager.spawn(kind: "explore", task_name: "explore", task: "inspect", mode: "async")
    agent.started.pop

    result = JSON.parse(registry.fetch("interrupt_subagent").execute({
      "subagent_id" => "/root/explore",
      "message" => "What are you checking?"
    }).content)
    snapshot = manager.list.dig(:subagents, 0)

    assert_equal "interruption_delivered", result.fetch("status")
    assert_equal "Still investigating", result.fetch("response")
    assert_equal "text_only", result.fetch("response_disposition")
    assert_equal "running", result.dig("subagent", "status")
    assert_equal ["What are you checking?"], agent.interruptions
    refute_nil agent.interrupt_target
    assert_equal 1, snapshot[:current_turn]
    assert_nil snapshot[:latest_turn]
    assert_equal 0, snapshot[:queued_turns]
    refute_includes registry.fetch("interrupt_subagent").input_schema.fetch("properties"), "mode"
  ensure
    gate&.open
    manager&.close
  end

  def test_successful_interrupt_exchange_is_persisted_and_visible_after_resume
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    gate = Gate.new
    started = Queue.new
    resumed_history = []
    builds = 0
    first_result = run_result("final answer")
    resumed_result = run_result("resumed answer")
    factory = lambda do |id|
      builds += 1
      agent = LittleGhost::Agent.new(model: Object.new, agent_path: id)
      if builds == 1
        agent.define_singleton_method(:stream) do |_message, **_options|
          Enumerator.new do |events|
            started << true
            gate.wait
            events << LittleGhost::StreamEvent.build(:invocation_stop, result: first_result)
          end
        end
        agent.define_singleton_method(:interrupt_response) do |_message, **_options|
          LittleGhost::AgentInterruptions::Response.new(text: "interrupt answer", tool_calls: false)
        end
      else
        agent.define_singleton_method(:stream) do |_message, **options|
          Enumerator.new do |events|
            resumed_history.concat(options.fetch(:history))
            events << LittleGhost::StreamEvent.build(:invocation_stop, result: resumed_result)
          end
        end
      end
      agent
    end
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory:
    )
    first_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    spawned = first_manager.spawn(kind: "explore", task_name: "explore", task: "initial task", mode: "async")
    subagent_id = spawned.dig(:subagent, :subagent_id)
    conversation_id = spawned.dig(:subagent, :conversation_id)
    started.pop

    interrupted = first_manager.interrupt(subagent_id:, message: "status?")
    gate.open
    assert_equal "finished", first_manager.wait(subagent_ids: [subagent_id]).fetch(:status)
    first_manager.close

    restored_parent = LittleGhost::Session.new(id: "parent", store:)
    second_manager = LittleGhost::Subagents::Manager.new([definition], parent_session: restored_parent)
    second_manager.send_message(subagent_id:, message: "continue", mode: "sync")
    child = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.conversation_session_id(conversation_id),
      store:
    )

    assert_equal "interrupt answer", interrupted.fetch(:response)
    assert_equal(
      ["initial task", "status?", "interrupt answer", "final answer"],
      resumed_history.first(4).map(&:text)
    )
    assert_equal %i[user user assistant assistant user assistant], child.history.map(&:role)
    assert_equal(
      ["initial task", "status?", "interrupt answer", "final answer", "continue", "resumed answer"],
      child.history.map(&:text)
    )
  ensure
    gate&.open
    first_manager&.close
    second_manager&.close
  end

  def test_interrupt_exchange_is_not_persisted_when_the_durable_turn_fails
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    gate = Gate.new
    started = Queue.new
    agent = LittleGhost::Agent.new(model: Object.new, agent_path: "/root/explore")
    agent.define_singleton_method(:stream) do |_message, **_options|
      Enumerator.new do |_events|
        started << true
        gate.wait
        raise "turn failed"
      end
    end
    agent.define_singleton_method(:interrupt_response) do |_message, **_options|
      LittleGhost::AgentInterruptions::Response.new(text: "temporary answer", tool_calls: false)
    end
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { agent }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "initial task", mode: "async")
    subagent_id = spawned.dig(:subagent, :subagent_id)
    conversation_id = spawned.dig(:subagent, :conversation_id)
    started.pop

    manager.interrupt(subagent_id:, message: "status?")
    gate.open
    _out, _err = capture_io { manager.wait(subagent_ids: [subagent_id]) }
    child = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.conversation_session_id(conversation_id),
      store:
    )

    assert_empty child.history
    refute parent.state.key?("little_ghost.subagent_conversations")
  ensure
    gate&.open
    manager&.close
  end

  def test_interrupt_exchange_is_not_persisted_when_the_durable_turn_is_cancelled
    store = LittleGhost::SessionStores::Memory.new
    parent = LittleGhost::Session.new(id: "parent", store:)
    gate = Gate.new
    started = Queue.new
    agent = LittleGhost::Agent.new(model: Object.new, agent_path: "/root/explore")
    agent.define_singleton_method(:stream) do |_message, **options|
      Enumerator.new do |_events|
        started << true
        gate.wait
        options.fetch(:cancellation_token).raise_if_cancelled!
      end
    end
    agent.define_singleton_method(:interrupt_response) do |_message, **_options|
      LittleGhost::AgentInterruptions::Response.new(text: "temporary answer", tool_calls: false)
    end
    definition = LittleGhost::Subagents::Definition.new(
      kind: "explore",
      description: "Explore code",
      factory: ->(_id) { agent }
    )
    manager = LittleGhost::Subagents::Manager.new([definition], parent_session: parent)
    spawned = manager.spawn(kind: "explore", task_name: "explore", task: "initial task", mode: "async")
    subagent_id = spawned.dig(:subagent, :subagent_id)
    conversation_id = spawned.dig(:subagent, :conversation_id)
    started.pop
    manager.interrupt(subagent_id:, message: "status?")

    closer = Thread.new { manager.close }
    wait_until { manager.list.dig(:subagents, 0, :status) == "cancelled" }
    gate.open
    closer.value
    child = LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.conversation_session_id(conversation_id),
      store:
    )

    assert_empty child.history
    refute parent.state.key?("little_ghost.subagent_conversations")
  ensure
    gate&.open
    closer&.join
    manager&.close
  end

  private

  def seed_durable_registry(store:, parent:, records:)
    parent_link = LittleGhost::Subagents::Manager.parent_link(parent)
    conversations = {}
    records.each do |record|
      child_metadata = {
        "little_ghost_kind" => "subagent_conversation",
        "little_ghost_parent_link" => parent_link,
        "little_ghost_conversation_id" => record.fetch(:conversation_id)
      }
      LittleGhost::Session.new(
        id: LittleGhost::Subagents::Manager.conversation_session_id(record.fetch(:conversation_id)),
        store:,
        metadata: child_metadata
      ).replace(
        messages: record.fetch(:messages),
        state: record.fetch(:state, {}),
        metadata: child_metadata
      )
      commit_metadata = {
        "little_ghost_kind" => "subagent_commit",
        "little_ghost_parent_link" => parent_link,
        "little_ghost_conversation_id" => record.fetch(:conversation_id),
        "little_ghost_commit_id" => record.fetch(:commit_id),
        "little_ghost_message_count" => record.fetch(:messages).length
      }
      LittleGhost::Session.new(
        id: LittleGhost::Subagents::Manager.commit_session_id(record.fetch(:conversation_id), 0),
        store:,
        metadata: commit_metadata
      ).replace(messages: [], state: record.fetch(:state, {}), metadata: commit_metadata)
      conversations[record.fetch(:subagent_id)] = {
        "conversation_id" => record.fetch(:conversation_id),
        "kind" => record.fetch(:kind),
        "latest_turn" => record.fetch(:latest_turn, 1),
        "updated_at" => record.fetch(:updated_at),
        "message_count" => record.fetch(:messages).length,
        "commit_id" => record.fetch(:commit_id),
        "commit_slot" => 0
      }
    end
    metadata = {
      "little_ghost_kind" => "subagent_registry",
      "little_ghost_parent_link" => parent_link
    }
    LittleGhost::Session.new(
      id: LittleGhost::Subagents::Manager.registry_session_id(parent),
      store:,
      metadata:
    ).replace(
      messages: [],
      state: {
        "version" => LittleGhost::Subagents::Manager::REGISTRY_VERSION,
        "conversations" => conversations
      },
      metadata:
    )
  end

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

  def streaming_agent(&body)
    agent = LittleGhost::Agent.new(model: Object.new, agent_path: "/root/explore")
    agent.define_singleton_method(:stream) do |_message, **_options|
      Enumerator.new { |stream| body.call(stream) }
    end
    agent
  end

  def model_response(text, stop_reason:, tool_use: nil)
    content = [text]
    content << tool_use if tool_use
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content:),
      stop_reason:,
      usage: LittleGhost::Usage.new
    )
  end

  def run_result(text)
    message = LittleGhost::Message.new(role: :assistant, content: text)
    LittleGhost::RunResult.new(
      message:,
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new,
      messages: [message],
      state: {}
    )
  end

  def wait_until(timeout: 1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for condition" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
