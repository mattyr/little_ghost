# frozen_string_literal: true

require "test_helper"

class AgentContextManagementTest < Minitest::Test
  class ScriptedModel
    attr_reader :requests

    def initialize(*responses, metadata: {})
      @responses = responses
      @requests = []
      @metadata = metadata
    end

    attr_reader :metadata

    def stream(request)
      @requests << request
      response = @responses.shift
      raise response if response.is_a?(Exception)

      [LittleGhost::StreamEvent.build(:message_stop, response: response)].each
    end
  end

  class CancellingSummaryModel
    attr_reader :requests

    def initialize
      @requests = []
    end

    def stream(request)
      requests << request
      request.cancellation_token.cancel
      [LittleGhost::StreamEvent.build(:message_start)].each
    end
  end

  def test_summarizes_old_context_and_includes_its_usage
    summary_usage = LittleGhost::Usage.new(input_tokens: 10, output_tokens: 2)
    final_usage = LittleGhost::Usage.new(input_tokens: 3, output_tokens: 1)
    model = ScriptedModel.new(response("summary", usage: summary_usage), response("done", usage: final_usage))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end
    telemetry = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { telemetry << [name, attributes] })

    result = agent_class.new(model:, instrumentation:).call("current", history: history)

    assert_equal 2, model.requests.length
    assert_empty model.requests.first.tools
    assert_includes model.requests.first.messages.first.text, "conversation summarizer"
    assert_equal "summary", model.requests.last.messages.first.text
    refute_includes model.requests.last.messages.map(&:text).join, "message-0-"
    assert_equal 16, result.usage.total_tokens
    assert_equal "done", result.text
    turn_id = telemetry.assoc(:agent_turn_start).last.fetch(:operation_id)
    model_parents = telemetry.filter_map do |name, attributes|
      attributes[:parent_operation_id] if name == :model_start
    end
    assert_equal [turn_id, turn_id], model_parents
  end

  def test_preserves_tool_calls_with_their_results_at_the_summary_boundary
    model = ScriptedModel.new(response("summary"), response("done"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 80, compression_threshold: 0.1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup", input: {})
    tool_result = LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "found", status: :success)
    history = [
      LittleGhost::Message.new(role: :user, content: "question"),
      LittleGhost::Message.new(role: :assistant, content: tool_use),
      LittleGhost::Message.new(role: :tool, content: tool_result),
      LittleGhost::Message.new(role: :assistant, content: "answer"),
      LittleGhost::Message.new(role: :user, content: "next")
    ]

    agent_class.new(model: model).call("current", history: history)

    remaining = model.requests.last.messages
    refute remaining.any? { |message| message.content.any? { |block| block.is_a?(LittleGhost::Content::ToolResult) } } ^
      remaining.any? { |message| message.content.any? { |block| block.is_a?(LittleGhost::Content::ToolUse) } }
  end

  def test_validates_context_management_configuration
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context context_window_tokens: 0 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context compression_threshold: 2 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context summary_ratio: 0.01 } }
    assert_raises(ArgumentError) { Class.new(LittleGhost::Agent) { manage_context preserve_recent_messages: 1 } }
  end

  def test_recovers_when_the_provider_reports_a_context_overflow
    model = ScriptedModel.new(
      LittleGhost::ContextWindowOverflowError.new("too large"),
      response("summary", usage: LittleGhost::Usage.new(input_tokens: 4, output_tokens: 2)),
      response("done", usage: LittleGhost::Usage.new(input_tokens: 3, output_tokens: 1))
    )
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 1_000_000, compression_threshold: 1,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    result = agent_class.new(model: model).call("current", history:)

    assert_equal 3, model.requests.length
    assert_equal "summary", model.requests.last.messages.first.text
    assert_equal "done", result.text
    assert_equal 10, result.usage.total_tokens
  end

  def test_context_compaction_propagates_cleanup_errors
    cleanup_error = LittleGhost::CleanupError.new("summary work is still running")
    model = ScriptedModel.new(cleanup_error, response("must not continue"))
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    raised = assert_raises(LittleGhost::CleanupError) do
      agent_class.new(model: model).call("current", history:)
    end

    assert_same cleanup_error, raised
    assert_equal 1, model.requests.length
  end

  def test_context_compaction_propagates_cancellation_from_the_summary_request
    model = CancellingSummaryModel.new
    token = LittleGhost::Support::CancellationToken.new
    agent_class = Class.new(LittleGhost::Agent) do
      manage_context context_window_tokens: 120, compression_threshold: 0.5,
        summary_ratio: 0.5, preserve_recent_messages: 2
    end
    history = 8.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}-#{"x" * 50}")
    end

    assert_raises(LittleGhost::CancelledError) do
      agent_class.new(model: model).call("current", history:, cancellation_token: token)
    end

    assert token.cancelled?
    assert_equal 1, model.requests.length
    assert_empty model.requests.first.tools
  end

  private

  def response(text, usage: LittleGhost::Usage.new)
    LittleGhost::ModelResponse.new(
      message: LittleGhost::Message.new(role: :assistant, content: text),
      stop_reason: :end_turn,
      usage: usage
    )
  end
end
