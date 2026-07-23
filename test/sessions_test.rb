# frozen_string_literal: true

require "test_helper"

class SessionsTest < Minitest::Test
  def test_memory_store_persists_messages_state_and_metadata
    store = LittleGhost::SessionStores::Memory.new
    session = LittleGhost::Session.new(
      id: "conversation",
      actor_id: "actor",
      store:,
      metadata: {source: "test"}
    )

    session.checkpoint(
      messages: [
        LittleGhost::Message.new(role: :system, content: "Do not persist"),
        LittleGhost::Message.new(role: :user, content: "Hello")
      ],
      state: {calls: 1}
    )
    reopened = LittleGhost::Session.new(id: "conversation", actor_id: "actor", store:)

    assert_equal ["Hello"], reopened.history.map(&:text)
    assert_equal({calls: 1}, reopened.state)
    assert_equal({source: "test"}, reopened.metadata)
  end

  def test_checkpoint_result_preserves_stored_metadata
    store = LittleGhost::SessionStores::Memory.new
    store.replace(
      "conversation",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "Hello")],
      state: {},
      metadata: {source: "stored"}
    )
    session = LittleGhost::Session.new(id: "conversation", actor_id: "actor", store:)
    messages = [LittleGhost::Message.new(role: :assistant, content: "Done")]
    result = Struct.new(:messages, :state).new(messages, {complete: true})

    session.checkpoint_result(result)

    snapshot = store.load("conversation", actor_id: "actor")
    assert_equal({source: "stored"}, snapshot.fetch(:metadata))
  end

  def test_checkpoints_without_private_model_reasoning
    store = LittleGhost::SessionStores::Memory.new
    session = LittleGhost::Session.new(id: "conversation", actor_id: "actor", store:)
    private_reasoning = "private chain of thought"
    private_reasoning_detail = "private signed reasoning"
    tool_use = LittleGhost::Content::ToolUse.new(id: "call-1", name: "lookup", input: {})

    session.checkpoint(messages: [
      LittleGhost::Message.new(role: :assistant, content: [
        LittleGhost::Content::Reasoning.new(
          text: private_reasoning,
          details: [{"type" => "reasoning.text", "index" => 0, "text" => private_reasoning_detail}]
        ),
        tool_use
      ]),
      LittleGhost::Message.new(
        role: :assistant,
        content: LittleGhost::Content::Reasoning.new(text: "reasoning without visible output")
      )
    ])

    snapshot = store.load("conversation", actor_id: "actor")
    assert_equal 1, snapshot.fetch(:messages).length
    assert_equal [tool_use], snapshot.fetch(:messages).fetch(0).content
    refute_includes JSON.generate(snapshot.fetch(:messages).map(&:to_h)), private_reasoning
    refute_includes JSON.generate(snapshot.fetch(:messages).map(&:to_h)), private_reasoning_detail
    refute snapshot.fetch(:messages).flat_map(&:content).any? { |block| block.is_a?(LittleGhost::Content::Reasoning) }
  end

  def test_memory_store_rejects_another_actor
    store = LittleGhost::SessionStores::Memory.new
    store.replace("conversation", actor_id: "first", messages: [], state: {}, metadata: {})
    session = LittleGhost::Session.new(id: "conversation", actor_id: "second", store:)

    assert_raises(LittleGhost::Error) { session.load }
  end

  def test_first_actor_claim_is_atomic
    store = LittleGhost::SessionStores::Memory.new
    outcomes = %w[first second].map do |actor|
      Thread.new do
        store.load("conversation", actor_id: actor)
        actor
      rescue LittleGhost::Error
        :rejected
      end
    end.map(&:value)

    assert_equal 1, outcomes.count(:rejected)
    assert_equal 1, (outcomes & %w[first second]).length
  end

  def test_store_serializes_sessions_with_the_same_identity
    store = LittleGhost::SessionStores::Memory.new
    sessions = 2.times.map do
      LittleGhost::Session.new(id: "conversation", actor_id: "actor", store:)
    end
    active = 0
    maximum = 0
    mutex = Mutex.new

    sessions.map do |session|
      Thread.new do
        session.synchronize do
          mutex.synchronize do
            active += 1
            maximum = [maximum, active].max
          end
          sleep(0.01)
          mutex.synchronize { active -= 1 }
        end
      end
    end.each(&:join)

    assert_equal 1, maximum
  end

  def test_store_does_not_serialize_different_sessions
    store = LittleGhost::SessionStores::Memory.new
    sessions = %w[first second].map do |id|
      LittleGhost::Session.new(id:, actor_id: "actor", store:)
    end
    active = 0
    maximum = 0
    mutex = Mutex.new

    sessions.map do |session|
      Thread.new do
        session.synchronize do
          mutex.synchronize do
            active += 1
            maximum = [maximum, active].max
          end
          sleep(0.01)
          mutex.synchronize { active -= 1 }
        end
      end
    end.each(&:join)

    assert_equal 2, maximum
  end

  def test_invalid_store_values_raise_a_protocol_error
    store = Class.new(LittleGhost::SessionStore) do
      def load(_id, actor_id: nil) = {messages: Object.new}
      def append(*) = nil
      def replace(*) = nil
    end.new
    session = LittleGhost::Session.new(id: "conversation", store:)

    error = assert_raises(LittleGhost::ProtocolError) { session.load }

    assert_includes error.message, "invalid value"
  end

  def test_checkpoint_failures_raise
    store = Class.new(LittleGhost::SessionStore) do
      def load(_id, actor_id: nil) = nil
      def append(*) = raise("offline")
      def replace(*) = raise("offline")
    end.new
    session = LittleGhost::Session.new(id: "conversation", store:)

    error = assert_raises(RuntimeError) do
      session.checkpoint(messages: [LittleGhost::Message.new(role: :user, content: "Hello")])
    end

    assert_equal "offline", error.message
  end
end
