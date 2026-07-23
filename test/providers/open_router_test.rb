# frozen_string_literal: true

require "test_helper"
require "little_ghost/providers/open_router"

class OpenRouterTest < Minitest::Test
  class CaptureTransport
    attr_reader :request

    def stream(**request)
      @request = request
      yield "data: [DONE]\n\n"
    end
  end

  def test_adds_attribution_session_reasoning_and_cache_settings
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::OpenRouter.new(
      api_key: "secret",
      model: "openai/gpt-test",
      site_url: "https://example.test",
      app_name: "LittleGhost",
      transport:
    )
    request = LittleGhost::ModelRequest.new(
      messages: [{role: :user, content: "Hello"}],
      settings: {reasoning_effort: "high", session_id: "session-1", prompt_cache_key: "cache-1"}
    )

    provider.stream(request).to_a

    assert_equal "https://example.test", transport.request[:headers]["HTTP-Referer"]
    assert_equal "LittleGhost", transport.request[:headers]["X-Title"]
    assert_equal "session-1", transport.request[:headers]["x-session-id"]
    body = JSON.parse(transport.request[:body])
    assert_equal({"effort" => "high"}, body["reasoning"])
    assert_equal "session-1", body["session_id"]
    assert_equal "cache-1", body["prompt_cache_key"]
  end

  def test_uses_top_level_cache_control_for_anthropic
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::OpenRouter.new(api_key: "secret", model: "anthropic/claude-sonnet-4", transport:)

    provider.stream(request).to_a

    assert_equal({"type" => "ephemeral"}, JSON.parse(transport.request[:body])["cache_control"])
  end

  def test_marks_the_first_system_message_for_gemini_cache_control
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::OpenRouter.new(api_key: "secret", model: "google/gemini-3.5-flash", transport:)

    provider.stream(request(messages: [{role: :system, content: "Stable"}, {role: :user, content: "Dynamic"}])).to_a

    content = JSON.parse(transport.request[:body]).dig("messages", 0, "content", 0)
    assert_equal({"type" => "ephemeral"}, content["cache_control"])
  end

  def test_replays_reasoning_details_for_a_tool_continuation
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::OpenRouter.new(
      api_key: "secret",
      model: "openai/gpt-test",
      transport:
    )
    reasoning_details = [
      {
        "type" => "reasoning.text", "index" => 0,
        "format" => "openai-responses-v1", "text" => "Think carefully", "signature" => "signed"
      }
    ]
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup", input: {"id" => 1})
    tool_result = LittleGhost::Content::ToolResult.new(tool_use_id: "call-1", content: "found", status: :success)

    provider.stream(request(messages: [
      {
        role: :assistant,
        content: [LittleGhost::Content::Reasoning.new(text: "Think carefully", details: reasoning_details), tool_use]
      },
      {role: :tool, content: [tool_result]}
    ])).to_a

    body = JSON.parse(transport.request[:body])
    assistant = body.fetch("messages").fetch(0)
    assert_equal "Think carefully", assistant["reasoning"]
    assert_equal reasoning_details, assistant["reasoning_details"]
    assert_equal "lookup", assistant.dig("tool_calls", 0, "function", "name")
    assert_nil assistant["content"]
    assert_equal "found", body.dig("messages", 1, "content")
  end

  def test_does_not_attach_reasoning_fields_to_non_assistant_messages
    transport = CaptureTransport.new
    provider = LittleGhost::Providers::OpenRouter.new(
      api_key: "secret",
      model: "openai/gpt-test",
      transport:
    )

    provider.stream(request(messages: [
      {
        role: :user,
        content: LittleGhost::Content::Reasoning.new(
          text: "invalid",
          details: [{"type" => "reasoning.text", "index" => 0, "text" => "invalid"}]
        )
      }
    ])).to_a

    body = JSON.parse(transport.request[:body])
    assert_empty body.fetch("messages")
  end

  private

  def request(messages: [{role: :user, content: "Hello"}])
    LittleGhost::ModelRequest.new(messages:)
  end
end
