# frozen_string_literal: true

require "test_helper"

class AnthropicTest < Minitest::Test
  class Transport
    attr_reader :arguments

    def initialize(frames)
      @frames = frames
    end

    def stream(**arguments)
      @arguments = arguments
      @frames.each { |frame| yield "data: #{JSON.generate(frame)}\n\n" }
    end
  end

  def test_streams_text_tools_usage_and_builds_messages_request
    frames = [
      {type: "message_start", message: {id: "message-1", model: "claude", usage: {input_tokens: 5}}},
      {type: "content_block_start", index: 0, content_block: {type: "text"}},
      {type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "Hello"}},
      {type: "content_block_start", index: 1, content_block: {type: "tool_use", id: "tool-1", name: "lookup"}},
      {type: "content_block_delta", index: 1, delta: {type: "input_json_delta", partial_json: "{\"id\":1}"}},
      {type: "content_block_stop", index: 1},
      {type: "message_delta", delta: {stop_reason: "tool_use"}, usage: {output_tokens: 3}},
      {type: "message_stop"}
    ]
    transport = Transport.new(frames)
    provider = LittleGhost::Providers::Anthropic.new(api_key: "secret", model: "claude", transport:)
    request = LittleGhost::ModelRequest.new(messages: [LittleGhost::Message.new(role: :user, content: "Hi")])

    events = provider.stream(request).to_a

    assert_equal %i[message_start text_delta tool_call_start tool_call_delta tool_call_stop usage message_stop], events.map(&:type)
    assert_equal({"id" => 1}, events.last.data[:response].message.content.last.input)
    body = JSON.parse(transport.arguments.fetch(:body))
    assert_equal "claude", body.fetch("model")
    assert_equal "secret", transport.arguments.dig(:headers, "x-api-key")
  end
end
