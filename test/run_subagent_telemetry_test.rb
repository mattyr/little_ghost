# frozen_string_literal: true

require "test_helper"

class RunSubagentTelemetryTest < Minitest::Test
  def test_correlates_concurrent_manager_turns_by_unique_operation_id
    run = LittleGhost::Run.allocate
    run.instance_variable_set(:@operation_id, "root-run")
    run.instance_variable_set(:@subagent_started_at, {})

    first_start = telemetry(run, {
      event: "spawned",
      subagent_id: "evidence-1",
      kind: "evidence",
      turn: 1,
      operation_id: "first-turn",
      parent_operation_id: "first-investigator"
    })
    second_start = telemetry(run, {
      event: "message_queued",
      subagent_id: "evidence-1",
      kind: "evidence",
      turn: 1,
      operation_id: "second-turn",
      parent_operation_id: "second-investigator"
    })
    second_stop = telemetry(run, {
      event: "turn_finished",
      subagent_id: "evidence-1",
      kind: "evidence",
      turn: 1,
      operation_id: "second-turn",
      parent_operation_id: "second-investigator"
    })
    first_stop = telemetry(run, {
      event: "turn_finished",
      subagent_id: "evidence-1",
      kind: "evidence",
      turn: 1,
      operation_id: "first-turn",
      parent_operation_id: "first-investigator"
    })

    assert_equal [:subagent_start, "first-turn", "first-investigator"],
      event_identity(first_start)
    assert_equal [:subagent_start, "second-turn", "second-investigator"],
      event_identity(second_start)
    assert_equal [:subagent_stop, "second-turn", "second-investigator"],
      event_identity(second_stop)
    assert_equal [:subagent_stop, "first-turn", "first-investigator"],
      event_identity(first_stop)
    assert_equal "evidence-1", first_start.last.fetch(:agent_id)
    assert_operator first_stop.last.fetch(:duration_ms), :>=, 0
    assert_operator second_stop.last.fetch(:duration_ms), :>=, 0

    started = telemetry(run, {
      event: "turn_started",
      subagent_id: "evidence-1",
      kind: "evidence",
      turn: 2,
      operation_id: "third-turn",
      parent_operation_id: "first-investigator"
    })
    assert_equal :subagent_turn_started, started.first
    assert_equal "third-turn", started.last.fetch(:operation_id)
  end

  private

  def telemetry(run, event)
    run.send(:subagent_telemetry, event:)
  end

  def event_identity(telemetry)
    name, attributes = telemetry
    [name, attributes.fetch(:operation_id), attributes.fetch(:parent_operation_id)]
  end
end
