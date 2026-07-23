# frozen_string_literal: true

require "test_helper"

class WriteTodosTest < Minitest::Test
  def test_replaces_the_plan_in_run_context
    context = LittleGhost::RunContext.new(state: {})
    tool = LittleGhost::Tools::WriteTodos.new
    result = tool.execute({
      "plan_title" => "Ship it",
      "todos" => [{"id" => "one", "title" => "Build", "status" => "in_progress"}]
    }, context:)

    assert result.success?
    assert_equal "Ship it", context.state.dig("little_ghost.plan", "plan_title")
    assert_equal "Ship it", JSON.parse(result.content).fetch("plan_title")
  end

  def test_rejects_duplicate_ids_and_multiple_in_progress_todos
    tool = LittleGhost::Tools::WriteTodos.new

    duplicates = tool.execute({
      "plan_title" => "Duplicates",
      "todos" => [
        {"id" => "one", "title" => "First", "status" => "pending"},
        {"id" => "one", "title" => "Second", "status" => "completed"}
      ]
    })
    multiple_active = tool.execute({
      "plan_title" => "Too many active todos",
      "todos" => [
        {"id" => "one", "title" => "First", "status" => "in_progress"},
        {"id" => "two", "title" => "Second", "status" => "in_progress"}
      ]
    })

    assert duplicates.error?
    assert_includes duplicates.content, "unique"
    assert multiple_active.error?
    assert_includes multiple_active.content, "only one"
  end

  def test_enforces_the_bounded_public_plan_contract
    tool = LittleGhost::Tools::WriteTodos.new

    missing_title = tool.execute({"todos" => []})
    invalid_id = tool.execute({
      "plan_title" => "Plan",
      "todos" => [{"id" => "INVALID", "title" => "Build", "status" => "pending"}]
    })
    too_many = tool.execute({
      "plan_title" => "Plan",
      "todos" => 21.times.map { |index| {"id" => "todo-#{index}", "title" => "Build", "status" => "pending"} }
    })

    assert missing_title.error?
    assert_includes missing_title.content, "plan_title is required"
    assert invalid_id.error?
    assert_includes invalid_id.content, "invalid format"
    assert too_many.error?
    assert_includes too_many.content, "at most 20"
  end

  def test_normalizes_titles_and_rejects_whitespace_only_titles
    context = LittleGhost::RunContext.new(state: {})
    tool = LittleGhost::Tools::WriteTodos.new

    normalized = tool.execute({
      "plan_title" => "  Ship it  ",
      "todos" => [{"id" => "one", "title" => "  Build  ", "status" => "pending"}]
    }, context:)
    blank_plan = tool.execute({"plan_title" => "   ", "todos" => []})
    blank_todo = tool.execute({
      "plan_title" => "Plan",
      "todos" => [{"id" => "one", "title" => "   ", "status" => "pending"}]
    })

    assert normalized.success?
    assert_equal "Ship it", context.state.dig("little_ghost.plan", "plan_title")
    assert_equal "Build", context.state.dig("little_ghost.plan", "todos", 0, "title")
    assert blank_plan.error?
    assert_includes blank_plan.content, "plan_title must have at least 1 characters"
    assert blank_todo.error?
    assert_includes blank_todo.content, "title must have at least 1 characters"
  end
end
