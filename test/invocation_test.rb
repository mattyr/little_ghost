# frozen_string_literal: true

require "test_helper"

class InvocationTest < Minitest::Test
  def test_is_an_open_indifferent_access_environment
    invocation = LittleGhost::Invocation.new("message" => "hello", "slack_context" => {"channel" => "C1"})

    assert_equal "hello", invocation.message.text
    assert_equal "C1", invocation.slack_context.fetch("channel")
    invocation[:prepared_attachments] = ["one"]
    invocation.presentation = "slack"
    assert_equal ["one"], invocation.fetch("prepared_attachments")
    assert_equal "slack", invocation.fetch(:presentation)
  end

  def test_defines_stable_identifiers
    invocation = LittleGhost::Invocation.new(message: "hello", session_id: "conversation", actor_id: "actor")

    assert_equal "conversation", invocation.session_id
    assert_equal "actor", invocation.actor_id
    assert_equal invocation.run_id, invocation.invocation_id
  end

  def test_nested_application_data_uses_string_keys_consistently
    invocation = LittleGhost::Invocation.new(
      message: "hello",
      interface_context: {interface: "slack"},
      attachments: [{kind: "image"}]
    )

    assert_equal "slack", invocation.dig(:interface_context, "interface")
    assert_equal "image", invocation.dig(:attachments, 0, "kind")
  end

  def test_generates_identifiers_and_fresh_collection_defaults
    first = LittleGhost::Invocation.new(message: "one")
    second = LittleGhost::Invocation.new(message: "two")

    assert_equal first.run_id, first.invocation_id
    assert_equal first.run_id, first.session_id
    refute_equal first.run_id, second.run_id
    refute_same first.history, second.history
    refute_same first.model_profiles, second.model_profiles
  end

  def test_parses_deadline_lazily_and_requires_a_message
    invocation = LittleGhost::Invocation.new(message: "work", deadline_at: "2026-07-21T12:00:00Z")

    assert_equal "work", invocation.message.text
    assert_equal Time.utc(2026, 7, 21, 12), invocation.deadline_at
    assert_raises(LittleGhost::InvocationError) { LittleGhost::Invocation.new }
    assert_raises(LittleGhost::InvocationError) do
      LittleGhost::Invocation.new(message: "hello", deadline_at: "eventually").deadline_at
    end
  end

  def test_copies_the_input_and_exports_a_copy
    payload = {metadata: {"mutable" => []}, message: "hello"}
    invocation = LittleGhost::Invocation.new(payload)
    payload[:metadata]["mutable"] << true

    assert_empty invocation.metadata.fetch("mutable")
    exported = invocation.to_h
    exported.fetch("metadata").fetch("mutable") << true
    assert_empty invocation.metadata.fetch("mutable")
  end
end
