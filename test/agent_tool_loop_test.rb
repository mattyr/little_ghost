# frozen_string_literal: true

require "test_helper"

class AgentToolLoopTest < Minitest::Test
  def test_warns_then_terminates_identical_tool_loop
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"q" => "same"})
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "same result" }.new
    result = LittleGhost::Tool::ExecutionResult.new(content: "same result", status: :success)

    first = call_tool(agent, tool_use, tool, result, context)
    second = call_tool(agent, tool_use.with(id: "2"), tool, result, context)
    third = call_tool(agent, tool_use.with(id: "3"), tool, result, context)
    fourth_before = run_callback(agent, :before_tool, {tool_use: tool_use.with(id: "4"), tool: tool}, context)

    assert first.continue?
    assert_includes second.value.fetch(:result).content, LittleGhost::Agent::ToolLoop::WARNING
    assert_includes third.value.fetch(:result).content, LittleGhost::Agent::ToolLoop::FINAL_WARNING
    assert fourth_before.cancel?
    assert_raises(LittleGhost::ToolLoopError) { run_callback(agent, :before_model, {}, context) }
  end

  def test_changed_result_resets_repeat_count
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new

    first = call_tool(agent, tool_use, tool, execution("one"), context)
    second = call_tool(agent, tool_use.with(id: "2"), tool, execution("two"), context)

    assert first.continue?
    assert second.continue?
  end

  def test_false_and_nil_tool_arguments_do_not_collide
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    false_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"enabled" => false})
    nil_use = LittleGhost::Content::ToolUse.new(id: "2", name: "search", input: {"enabled" => nil})

    first = call_tool(agent, false_use, tool, execution("same"), context)
    second = call_tool(agent, nil_use, tool, execution("same"), context)

    assert first.continue?
    assert second.continue?
  end

  def test_concurrent_invocations_have_independent_loop_state
    agent = build_agent
    first_context = LittleGhost::RunContext.new
    second_context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, first_context)
    run_callback(agent, :before_invocation, {}, second_context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    call_tool(agent, use, tool, execution("same"), first_context)
    first_repeat = call_tool(agent, use.with(id: "2"), tool, execution("same"), first_context)
    second_first = call_tool(agent, use.with(id: "3"), tool, execution("same"), second_context)

    assert first_repeat.replace?
    assert second_first.continue?
  end

  def test_active_invocation_loop_state_survives_garbage_collection
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    assert call_tool(agent, use, tool, execution("same"), context).continue?
    GC.start
    warning = call_tool(agent, use.with(id: "2"), tool, execution("same"), context)

    assert warning.replace?
    assert_includes warning.value.fetch(:result).content, LittleGhost::Agent::ToolLoop::WARNING
  end

  def test_bounds_invocation_state_left_by_failed_runs
    agent = build_agent
    limit = LittleGhost::Agent::ToolLoop::TRACKED_INVOCATION_LIMIT

    (limit + 1).times do
      run_callback(agent, :before_invocation, {}, LittleGhost::RunContext.new)
    end

    states = agent.instance_variable_get(:@tool_loop_runs)
    assert_equal limit, states.length
  end

  def test_parallel_identical_calls_count_as_one_repetition
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    first = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {"q" => "same"})
    second = first.with(id: "2")

    assert run_callback(agent, :before_tool, {tool_use: first, tool: tool}, context).continue?
    assert run_callback(agent, :before_tool, {tool_use: second, tool: tool}, context).continue?
    assert run_callback(agent, :after_tool, {tool_use: second, tool: tool, result: execution("same")}, context).continue?
    assert run_callback(agent, :after_tool, {tool_use: first, tool: tool, result: execution("same")}, context).continue?

    next_call = call_tool(agent, first.with(id: "3"), tool, execution("same"), context)
    assert next_call.replace?
    assert_includes next_call.value.fetch(:result).content, LittleGhost::Agent::ToolLoop::WARNING
  end

  def test_still_working_subagent_waits_do_not_count_as_repetitions
    agent = build_agent
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "wait_for_subagents", description: "Wait") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "wait_for_subagents", input: {})
    working = execution(JSON.generate(status: "still_working"))

    4.times do |index|
      assert call_tool(agent, use.with(id: index.to_s), tool, working, context).continue?
    end

    finished = execution(JSON.generate(status: "finished"))
    assert call_tool(agent, use.with(id: "finished-1"), tool, finished, context).continue?
    warning = call_tool(agent, use.with(id: "finished-2"), tool, finished, context)
    assert warning.replace?
  end

  def test_emits_only_one_termination_decision_for_parallel_calls
    events = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { events << [name, attributes] })
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4
    end
    agent = agent_class.new(model: Object.new, instrumentation: instrumentation)
    context = LittleGhost::RunContext.new(instrumentation: instrumentation)
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})
    3.times { |index| call_tool(agent, use.with(id: index.to_s), tool, execution("same"), context) }

    decisions = 2.times.map do |index|
      run_callback(agent, :before_tool, {tool_use: use.with(id: "terminal-#{index}"), tool: tool}, context)
    end

    assert decisions.all?(&:cancel?)
    terminations = events.select { |name, attributes| name == :tool_loop && attributes[:action] == :terminate }
    assert_equal 1, terminations.length
  end

  def test_composes_with_tool_result_offloading
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4
      offload_large_tool_results max_chars: 1, preview_chars: 1
    end
    agent = agent_class.new(model: Object.new)
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    first = call_tool(agent, tool_use, tool, execution("same"), context)
    call_tool(agent, tool_use.with(id: "2"), tool, execution("same"), context)
    call_tool(agent, tool_use.with(id: "3"), tool, execution("same"), context)
    fourth = run_callback(agent, :before_tool, {tool_use: tool_use.with(id: "4"), tool: tool}, context)

    assert first.replace?
    assert_includes first.value.fetch(:result).content, "[Offloaded:"
    assert fourth.cancel?
    assert_raises(LittleGhost::ToolLoopError) { run_callback(agent, :before_model, {}, context) }
  end

  def test_observes_raw_results_when_tool_result_offloading_is_declared_first
    agent_class = Class.new(LittleGhost::Agent) do
      offload_large_tool_results max_chars: 1, preview_chars: 1
      detect_tool_loops warning_at: 2, terminate_at: 4
    end
    agent = agent_class.new(model: Object.new)
    context = LittleGhost::RunContext.new
    run_callback(agent, :before_invocation, {}, context)
    tool = LittleGhost::Tool.define(name: "search", description: "Search") { "result" }.new
    tool_use = LittleGhost::Content::ToolUse.new(id: "1", name: "search", input: {})

    call_tool(agent, tool_use, tool, execution("same"), context)
    call_tool(agent, tool_use.with(id: "2"), tool, execution("same"), context)
    call_tool(agent, tool_use.with(id: "3"), tool, execution("same"), context)
    fourth = run_callback(agent, :before_tool, {tool_use: tool_use.with(id: "4"), tool: tool}, context)

    assert fourth.cancel?
  end

  private

  def build_agent
    agent_class = Class.new(LittleGhost::Agent) do
      detect_tool_loops warning_at: 2, terminate_at: 4
    end
    agent_class.new(model: Object.new)
  end

  def call_tool(agent, tool_use, tool, result, context)
    before = run_callback(agent, :before_tool, {tool_use: tool_use, tool: tool}, context)
    return before unless before.continue?

    run_callback(agent, :after_tool, {tool_use: tool_use, tool: tool, result: result}, context)
  end

  def run_callback(agent, name, payload, context)
    agent.send(:run_callbacks, name, payload, context:)
  end

  def execution(content)
    LittleGhost::Tool::ExecutionResult.new(content: content, status: :success)
  end
end
