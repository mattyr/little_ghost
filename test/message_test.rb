# frozen_string_literal: true

require "json"
require "test_helper"

class MessageTest < Minitest::Test
  def test_invocation_normalizes_history_and_current_message
    invocation = LittleGhost::Invocation.new(
      message: "Current",
      history: [{role: "assistant", content: "Earlier"}]
    )

    assert_equal :user, invocation.message.role
    assert_equal "Current", invocation.message.text
    assert_equal [:assistant], invocation.history.map(&:role)
    assert_equal "Earlier", invocation.history.first.text
  end

  def test_invocation_accepts_a_serialized_current_message
    invocation = LittleGhost::Invocation.new(
      message: {role: "user", content: [{type: "text", text: "Current"}]}
    )

    assert_equal :user, invocation.message.role
    assert_equal "Current", invocation.message.text
  end

  def test_messages_round_trip_as_json_with_binary_content
    message = LittleGhost::Message.new(role: :user, content: [
      LittleGhost::Content::Image.new(data: "\x00\xFF".b, media_type: "image/png"),
      LittleGhost::Content::Document.new(data: "document".b, media_type: "text/plain", name: "note.txt")
    ])

    decoded = LittleGhost::Message.coerce(JSON.parse(JSON.generate(message)))

    assert_equal message.role, decoded.role
    assert_equal message.content, decoded.content
  end

  def test_messages_round_trip_nested_tool_result_content
    message = LittleGhost::Message.new(
      role: :tool,
      content: LittleGhost::Content::ToolResult.new(
        tool_use_id: "call-1",
        content: [LittleGhost::Content::Text.new(text: "Found")],
        status: :success
      )
    )

    decoded = LittleGhost::Message.coerce(JSON.parse(JSON.generate(message)))

    assert_equal message.to_h, decoded.to_h
    assert_instance_of LittleGhost::Content::Text, decoded.content.first.content.first
  end

  def test_messages_round_trip_reasoning_details
    message = LittleGhost::Message.new(
      role: :assistant,
      content: LittleGhost::Content::Reasoning.new(
        text: "Thinking",
        details: [{"type" => "reasoning.text", "index" => 0, "text" => "Thinking", "signature" => "signed"}]
      )
    )

    decoded = LittleGhost::Message.coerce(JSON.parse(JSON.generate(message)))

    assert_equal message.to_h, decoded.to_h
    assert decoded.content.first.details.frozen?
  end

  def test_invalid_binary_content_has_a_coherent_error
    error = assert_raises(ArgumentError) do
      LittleGhost::Content.from_hash(type: "document", media_type: "text/plain", encoding: "base64")
    end

    assert_includes error.message, "Invalid document block"
  end

  def test_tool_content_enforces_canonical_protocol_fields
    assert_raises(ArgumentError) { LittleGhost::Content::ToolUse.new(id: "", name: "lookup", input: {}) }
    assert_raises(ArgumentError) { LittleGhost::Content::ToolUse.new(id: "call", name: nil, input: {}) }
    assert_raises(ArgumentError) { LittleGhost::Content::ToolUse.new(id: "call", name: "lookup", input: []) }
    assert_raises(ArgumentError) do
      LittleGhost::Content::ToolResult.new(tool_use_id: "call", content: "ok", status: :unknown)
    end
  end
end
