# frozen_string_literal: true

require "test_helper"
require "little_ghost/ag_ui"

class AGUITest < Minitest::Test
  def test_translates_generic_run_events
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "hello"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens: 2, output_tokens: 1),
      messages: [],
      state: {}
    )
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      LittleGhost::StreamEvent.build(:message_start),
      LittleGhost::StreamEvent.build(:text_delta, text: "hello"),
      LittleGhost::StreamEvent.build(:message_stop),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:run_stop, response: "hello")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM RUN_FINISHED],
      translated.map { |event| event[:type] }
    assert_equal "little_ghost.usage", translated[-2][:name]
    assert_equal 3, translated[-2].dig(:value, :usage, :total_tokens)
    assert_equal "hello", translated.last.dig(:result, :response)
  end

  def test_translates_tool_status_and_run_failure
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "lookup", input: {})
    result = LittleGhost::Tool::ExecutionResult.new(content: "failed", status: :error)
    events = [
      LittleGhost::StreamEvent.build(:run_start),
      LittleGhost::StreamEvent.build(:tool_stop, tool_use:, result:),
      LittleGhost::StreamEvent.build(:run_error, message: "Agent failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[RUN_STARTED TOOL_CALL_RESULT RUN_ERROR], translated.map { |event| event[:type] }
    assert_equal :error, translated[1][:status]
    assert_equal "Agent failed", translated.last[:message]
  end

  def test_translates_partial_and_cancelled_runs
    events = [
      LittleGhost::StreamEvent.build(:run_partial, response: "partial"),
      LittleGhost::StreamEvent.build(:run_cancel, error: LittleGhost::CancelledError.new("stopped"))
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[CUSTOM RUN_FINISHED CUSTOM RUN_FINISHED], translated.map { |event| event[:type] }
    assert_equal %w[little_ghost.run.partial little_ghost.run.canceled],
      translated.select { |event| event[:type] == "CUSTOM" }.map { |event| event[:name] }
  end

  def test_emits_aggregate_usage_before_an_abnormal_terminal_event
    usage = LittleGhost::Usage.new(
      input_tokens: 4,
      output_tokens: 2,
      cache_read_tokens: 3,
      reasoning_tokens: 1
    )
    events = [
      LittleGhost::StreamEvent.build(:usage, usage:),
      LittleGhost::StreamEvent.build(:invocation_error, error: RuntimeError.new("failed"), usage:),
      LittleGhost::StreamEvent.build(:run_error, message: "Agent failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[CUSTOM RUN_ERROR], translated.map { |event| event[:type] }
    assert_equal "little_ghost.usage", translated.first[:name]
    assert_equal 10, translated.first.dig(:value, :usage, :total_tokens)
    assert_equal 1, translated.count { |event| event[:name] == "little_ghost.usage" }
  end

  def test_closes_partial_text_before_a_model_retry
    source = [
      LittleGhost::StreamEvent.build(:text_delta, text: "Partial"),
      LittleGhost::StreamEvent.build(:model_retry, attempt: 1),
      LittleGhost::StreamEvent.build(:text_delta, text: "Complete"),
      LittleGhost::StreamEvent.build(:run_stop, response: "Complete")
    ]

    events = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a

    assert_equal(
      %w[
        TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM
        TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END RUN_FINISHED
      ],
      events.map { |event| event.fetch(:type) }
    )
    assert_equal "little_ghost.model_retry", events.fetch(3).fetch(:name)
  end

  def test_keeps_model_reasoning_private_while_preserving_visible_text_and_usage
    private_reasoning = "private chain of thought"
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "Visible answer"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(output_tokens: 2, reasoning_tokens: 7),
      messages: [],
      state: {}
    )
    source = [
      LittleGhost::StreamEvent.build(:text_delta, text: "Visible "),
      LittleGhost::StreamEvent.build(:reasoning_delta, text: private_reasoning),
      LittleGhost::StreamEvent.build(:text_delta, text: "answer"),
      LittleGhost::StreamEvent.build(:message_stop),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:run_stop, response: "Visible answer")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(source, thread_id: "thread", run_id: "run").to_a

    assert_equal %w[
      TEXT_MESSAGE_START TEXT_MESSAGE_CONTENT TEXT_MESSAGE_CONTENT TEXT_MESSAGE_END CUSTOM RUN_FINISHED
    ], translated.map { |event| event[:type] }
    assert_equal ["Visible ", "answer"], translated.select { |event|
      event[:type] == "TEXT_MESSAGE_CONTENT"
    }.map { |event| event[:delta] }
    assert_equal 7, translated.fetch(-2).dig(:value, :usage, :reasoning_tokens)
    refute_includes JSON.generate(translated), private_reasoning
    refute translated.any? { |event| event[:type].start_with?("REASONING") }
  end

  def test_closes_open_messages_before_terminal_events
    error_events = [
      LittleGhost::StreamEvent.build(:message_start),
      LittleGhost::StreamEvent.build(:reasoning_delta, text: "Checking"),
      LittleGhost::StreamEvent.build(:run_error, message: "Provider failed")
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(error_events, thread_id: "thread", run_id: "run").to_a

    assert_equal [
      "TEXT_MESSAGE_START",
      "TEXT_MESSAGE_END",
      "RUN_ERROR"
    ], translated.map { |event| event[:type] }

    %i[run_partial run_cancel run_stop].each do |type|
      data = (type == :run_partial || type == :run_stop) ? {response: "Partial"} : {}
      events = [
        LittleGhost::StreamEvent.build(:text_delta, text: "Partial"),
        LittleGhost::StreamEvent.build(type, **data)
      ]
      types = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").map { |event| event[:type] }

      assert_operator types.index("TEXT_MESSAGE_END"), :<, types.index("RUN_FINISHED")
    end
  end

  def test_emits_only_aggregate_usage_and_unwraps_trace_context
    result = LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: "done"),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2),
      messages: [],
      state: {}
    )
    events = [
      LittleGhost::StreamEvent.build(
        :usage,
        usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2),
        metadata: {model: "test"}
      ),
      LittleGhost::StreamEvent.build(:invocation_stop, result:),
      LittleGhost::StreamEvent.build(:trace_context, context: {trace_id: "abc"})
    ]

    translated = LittleGhost::AGUI::Adapter.new.stream(events, thread_id: "thread", run_id: "run").to_a

    assert_equal 1, translated.count { |event| event[:name] == "little_ghost.usage" }
    assert_equal 6, translated.first.dig(:value, :usage, :total_tokens)
    assert_equal({trace_id: "abc"}, translated.last[:value])
  end
end
