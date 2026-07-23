# frozen_string_literal: true

require "test_helper"

class AgentToolResultOffloadingTest < Minitest::Test
  def test_offloads_large_tool_results_and_retrieves_them
    agent = build_agent(max_chars: 5, preview_chars: 3)

    decision = offload(agent, tool: "search", content: "abcdefgh")
    reference = decision.value.fetch(:result).content.match(/\[Offloaded: ([^\]]+)\]/)[1]
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    assert decision.replace?
    assert_equal "abcdefgh", retrieval.execute({"reference" => reference}).content
  ensure
    agent&.close
  end

  def test_retrieves_matching_lines_with_bounded_context
    agent, reference = agent_with_offloaded_lines
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({
      "reference" => reference,
      "pattern" => "ERROR|warning",
      "context_lines" => 1
    }).content

    assert_includes content, "[2 matches for /ERROR|warning/]"
    assert_includes content, "  9| line 9"
    assert_includes content, "> 10| ERROR at line 10"
    assert_includes content, "> 30| warning at line 30"
    assert_includes content, "---"
    refute_includes content, "line 1\n"
  ensure
    agent&.close
  end

  def test_retrieves_an_inclusive_line_range
    agent, reference = agent_with_offloaded_lines
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({
      "reference" => reference,
      "line_range" => {"start" => 8, "end" => 10}
    }).content

    assert_includes content, "[Lines 8-10 of 40]"
    assert_includes content, "  8| line 8"
    assert_includes content, " 10| ERROR at line 10"
    refute_includes content, "line 7\n"
    refute_includes content, "line 11"
  ensure
    agent&.close
  end

  def test_context_lines_without_a_pattern_retrieves_the_first_lines
    agent, reference = agent_with_offloaded_lines
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({"reference" => reference, "context_lines" => 2}).content

    assert_includes content, "[Lines 1-2 of 40]"
    assert_includes content, " 1| line 1"
    assert_includes content, " 2| line 2"
    refute_includes content, "line 3"
  ensure
    agent&.close
  end

  def test_pattern_search_can_be_scoped_to_a_line_range
    agent, reference = agent_with_offloaded_lines
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({
      "reference" => reference,
      "pattern" => "warning",
      "line_range" => {"start" => 20, "end" => 35},
      "context_lines" => 0
    }).content

    assert_includes content, "[1 match for /warning/ in lines 20-35]"
    assert_includes content, "> 30| warning at line 30"
    refute_includes content, "ERROR"
  ensure
    agent&.close
  end

  def test_invalid_regex_is_treated_as_a_literal_pattern
    agent = build_agent(max_chars: 20, preview_chars: 0)
    reference = reference_from(offload(agent, tool: "search", content: "first\nvalue [open\nlast\nextra content"))
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({"reference" => reference, "pattern" => "[", "context_lines" => 0}).content

    assert_includes content, "1 match"
    assert_includes content, "value [open"
  ensure
    agent&.close
  end

  def test_bounded_retrieval_truncates_large_search_results
    agent = build_agent(max_chars: 40, preview_chars: 0)
    reference = reference_from(offload(agent, tool: "search", content: (["match"] * 30).join("\n")))
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    content = retrieval.execute({"reference" => reference, "pattern" => "match", "context_lines" => 0}).content

    assert_includes content, "[output truncated, narrow your search]"
    assert_operator content.length, :<, 120
  ensure
    agent&.close
  end

  def test_retrieval_schema_exposes_selective_read_parameters
    agent = build_agent
    schema = agent.tools.fetch("retrieve_offloaded_content").input_schema

    assert_equal %w[context_lines line_range pattern reference], schema.fetch("properties").keys.sort
    assert_equal %w[start end], schema.dig("properties", "line_range", "required")
  ensure
    agent&.close
  end

  def test_does_not_offload_excluded_tools
    agent = build_agent(max_chars: 1)

    assert offload(agent, tool: "skills", content: "long").continue?
    assert offload(agent, tool: "retrieve_offloaded_content", content: "long").continue?
  ensure
    agent&.close
  end

  def test_omits_entries_larger_than_the_per_entry_budget_but_keeps_the_preview
    agent = build_agent(
      max_chars: 1,
      preview_chars: 3,
      max_entry_bytes: 4,
      max_stored_bytes: 8
    )

    decision = offload(agent, tool: "search", content: "abcdefgh")
    content = decision.value.fetch(:result).content

    assert decision.replace?
    assert_includes content, "storage budget"
    assert_includes content, "abc"
    refute_includes content, "abcdefgh"
    refute_includes content, "Stored reference"
  ensure
    agent&.close
  end

  def test_omits_new_entries_when_the_aggregate_budget_is_full
    agent = build_agent(
      max_chars: 1,
      preview_chars: 2,
      max_entry_bytes: 8,
      max_stored_bytes: 8
    )
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    first = offload(agent, tool: "search", content: "abcd")
    first_reference = reference_from(first)
    second = offload(agent, tool: "search", content: "efghi")

    assert_equal "abcd", retrieval.execute({"reference" => first_reference}).content
    assert_includes second.value.fetch(:result).content, "ef"
    refute_includes second.value.fetch(:result).content, "Stored reference"
  ensure
    agent&.close
  end

  def test_omits_new_entries_without_evicting_retained_references_at_the_item_limit
    agent = build_agent(
      max_chars: 1,
      max_stored_items: 1,
      max_entry_bytes: 8,
      max_stored_bytes: 16
    )
    retrieval = agent.tools.fetch("retrieve_offloaded_content")

    first = offload(agent, tool: "search", content: "first")
    first_reference = reference_from(first)
    second = offload(agent, tool: "search", content: "second")

    assert_equal "first", retrieval.execute({"reference" => first_reference}).content
    refute_includes second.value.fetch(:result).content, "Stored reference"
  ensure
    agent&.close
  end

  def test_store_enforces_capacity_atomically_under_concurrent_writes
    store = LittleGhost::Agent::ToolResultOffloading::Store.new(
      max_items: 10,
      max_bytes: 100,
      max_entry_bytes: 10
    )
    writes = Queue.new
    threads = 100.times.map do |index|
      Thread.new do
        content = format("%010d", index)
        writes << [store.write(content), content]
      end
    end
    threads.each(&:join)
    retained = 100.times.filter_map do
      reference, content = writes.pop
      [reference, content] if reference
    end

    assert_equal 10, retained.length
    retained.each do |reference, content|
      assert_equal content, store.read(reference)
    end
  end

  def test_subagent_results_share_one_inline_budget_per_model_turn
    agent = build_agent(subagent_inline_tokens: 4)
    context = LittleGhost::RunContext.new
    agent.send(:reset_subagent_inline_budget, context: context)

    first = offload(agent, tool: "spawn_subagent", content: "a" * 8, context: context)
    second = offload(agent, tool: "send_message_to_subagent", content: "b" * 12, context: context)

    assert first.continue?
    assert second.replace?
    refute_includes second.value.fetch(:result).content, "b" * 12
    assert_includes second.value.fetch(:result).content, "shared inline budget"
    assert_includes second.value.fetch(:result).content, "[Stored reference:"
  ensure
    agent&.close
  end

  def test_subagent_inline_budget_resets_before_the_next_model_turn
    agent = build_agent(subagent_inline_tokens: 2)
    context = LittleGhost::RunContext.new
    agent.send(:reset_subagent_inline_budget, context: context)

    assert offload(agent, tool: "wait_for_subagents", content: "a" * 8, context: context).continue?
    assert offload(agent, tool: "wait_for_subagents", content: "b" * 8, context: context).replace?
    agent.send(:reset_subagent_inline_budget, context: context)
    assert offload(agent, tool: "wait_for_subagents", content: "c" * 8, context: context).continue?
  ensure
    agent&.close
  end

  def test_subagent_overflow_preserves_tool_loop_warnings_without_raw_content
    agent = build_agent(subagent_inline_tokens: 1)
    context = LittleGhost::RunContext.new
    warning = LittleGhost::Agent::ToolLoop::WARNING
    content = "#{warning}\n\n#{"secret" * 10}"

    decision = offload(agent, tool: "wait_for_subagents", content: content, context: context)

    assert decision.replace?
    assert_includes decision.value.fetch(:result).content, warning
    refute_includes decision.value.fetch(:result).content, "secret"
  ensure
    agent&.close
  end

  def test_subagent_overflow_safely_omits_content_larger_than_the_entry_budget
    agent = build_agent(
      subagent_inline_tokens: 1,
      max_entry_bytes: 4,
      max_stored_bytes: 8
    )
    context = LittleGhost::RunContext.new

    decision = offload(agent, tool: "wait_for_subagents", content: "sensitive", context: context)
    content = decision.value.fetch(:result).content

    assert decision.replace?
    assert_includes content, "could not be retained"
    refute_includes content, "sensitive"
    refute_includes content, "Stored reference"
  ensure
    agent&.close
  end

  def test_rejects_invalid_limits
    assert_raises(ArgumentError) { build_agent(max_chars: 0) }
    assert_raises(ArgumentError) { build_agent(preview_chars: -1) }
    assert_raises(ArgumentError) { build_agent(subagent_inline_tokens: 0) }
    assert_raises(ArgumentError) { build_agent(max_stored_items: 0) }
    assert_raises(ArgumentError) { build_agent(max_stored_bytes: 0) }
    assert_raises(ArgumentError) { build_agent(max_entry_bytes: 0) }
    assert_raises(ArgumentError) { build_agent(max_entry_bytes: 2, max_stored_bytes: 1) }
  end

  def test_configuration_does_not_retain_mutable_tool_names
    excluded_tool = +"search"
    agent_class = Class.new(LittleGhost::Agent) { offload_large_tool_results excluded_tools: [excluded_tool] }

    excluded_tool.replace("changed")

    assert_equal ["search"], agent_class.tool_result_offloading_configuration.fetch(:excluded_tools)
  end

  def test_each_agent_gets_its_own_store
    agent_class = Class.new(LittleGhost::Agent) { offload_large_tool_results }
    first = agent_class.new(model: Object.new)
    second = agent_class.new(model: Object.new)

    refute_same first.instance_variable_get(:@tool_result_store),
      second.instance_variable_get(:@tool_result_store)
  ensure
    first&.close
    second&.close
  end

  private

  def build_agent(**configuration)
    Class.new(LittleGhost::Agent) { offload_large_tool_results(**configuration) }.new(model: Object.new)
  end

  def offload(agent, tool:, content:, context: nil)
    payload = {
      tool_use: LittleGhost::Content::ToolUse.new(id: "1", name: tool, input: {}),
      result: LittleGhost::Tool::ExecutionResult.new(content:, status: :success)
    }
    agent.send(:offload_large_tool_result, payload, context: context)
  end

  def reference_from(decision)
    decision.value.fetch(:result).content.match(/\[Offloaded: ([^\]]+)\]/).captures.fetch(0)
  end

  def agent_with_offloaded_lines
    lines = (1..40).map do |line|
      case line
      when 10 then "ERROR at line 10"
      when 30 then "warning at line 30"
      else "line #{line}"
      end
    end
    agent = build_agent(max_chars: 200, preview_chars: 0)
    [agent, reference_from(offload(agent, tool: "search", content: lines.join("\n")))]
  end
end
