# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "test_helper"

class FilesystemSessionStoreTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("little-ghost-sessions")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_persists_messages_state_and_metadata_across_store_instances
    store = filesystem_store
    store.replace(
      "conversation",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "Hello")],
      state: {plan: {status: "active"}},
      metadata: {source: "test"}
    )

    snapshot = filesystem_store.load("conversation", actor_id: "actor")

    assert_equal ["Hello"], snapshot.fetch(:messages).map(&:text)
    assert_equal({plan: {status: "active"}}, snapshot.fetch(:state))
    assert_equal({source: "test"}, snapshot.fetch(:metadata))
  end

  def test_sessions_filter_private_messages_before_filesystem_persistence
    session = LittleGhost::Session.new(id: "conversation", actor_id: "actor", store: filesystem_store)
    session.checkpoint(messages: [
      LittleGhost::Message.new(role: :system, content: "Do not persist"),
      LittleGhost::Message.new(role: :user, content: "Keep me", metadata: {transient: true}),
      LittleGhost::Message.new(role: :user, content: "Keep this")
    ])

    snapshot = filesystem_store.load("conversation", actor_id: "actor")

    assert_equal ["Keep this"], snapshot.fetch(:messages).map(&:text)
  end

  def test_preserves_string_and_symbol_hash_keys
    filesystem_store.replace(
      "conversation",
      actor_id: "actor",
      messages: [],
      state: {"string" => {symbol: "value"}},
      metadata: {source: "test"}
    )

    snapshot = filesystem_store.load("conversation", actor_id: "actor")

    assert_equal({"string" => {symbol: "value"}}, snapshot.fetch(:state))
  end

  def test_rejects_another_actor_for_a_persisted_session
    filesystem_store.replace("conversation", actor_id: "first", messages: [], state: {}, metadata: {})

    assert_raises(LittleGhost::Error) { filesystem_store.load("conversation", actor_id: "second") }
  end

  def test_uses_opaque_paths_for_session_ids
    filesystem_store.replace("../../private/customer", actor_id: "actor", messages: [], state: {}, metadata: {})

    names = Dir.children(@root)

    assert names.all? { |name| name.match?(/\A[0-9a-f]{64}\.(json|lock)\z/) }
    refute names.any? { |name| name.include?("customer") }
  end

  def test_rejects_an_insecure_root
    File.chmod(0o755, @root)

    assert_raises(ArgumentError) { filesystem_store }
  end

  def test_rejects_a_symbolic_linked_snapshot
    store = filesystem_store
    store.replace("conversation", actor_id: "actor", messages: [], state: {}, metadata: {})
    path = snapshot_path
    original = "#{path}.original"
    File.rename(path, original)
    File.symlink(original, path)

    assert_raises(LittleGhost::ProtocolError) { store.load("conversation", actor_id: "actor") }
  end

  def test_rejects_a_snapshot_with_an_invalid_integrity_digest
    store = filesystem_store
    store.replace("conversation", actor_id: "actor", messages: [], state: {status: "original"}, metadata: {})
    path = snapshot_path
    document = JSON.parse(File.binread(path))
    document.fetch("snapshot").fetch("little_ghost:symbol:state")["little_ghost:string:status"] = "changed"
    File.binwrite(path, JSON.generate(document))

    assert_raises(LittleGhost::ProtocolError) { store.load("conversation", actor_id: "actor") }
  end

  def test_rejects_a_malformed_snapshot
    store = filesystem_store
    store.replace("conversation", actor_id: "actor", messages: [], state: {}, metadata: {})
    File.binwrite(snapshot_path, "not json")

    assert_raises(LittleGhost::ProtocolError) { store.load("conversation", actor_id: "actor") }
  end

  def test_rejects_unserializable_data_without_replacing_the_prior_snapshot
    store = filesystem_store
    store.replace("conversation", actor_id: "actor", messages: [], state: {status: "original"}, metadata: {})

    assert_raises(LittleGhost::ProtocolError) do
      store.replace("conversation", actor_id: "actor", messages: [], state: {status: Object.new}, metadata: {})
    end

    assert_equal({status: "original"}, store.load("conversation", actor_id: "actor").fetch(:state))
  end

  def test_rejects_a_stale_append_from_an_independent_store_instance
    first = filesystem_store
    second = filesystem_store

    assert_nil first.load("conversation", actor_id: "actor")
    second.append(
      "conversation",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "First")],
      state: {},
      metadata: {},
      expected_count: 0
    )

    assert_raises(LittleGhost::ProtocolError) do
      first.append(
        "conversation",
        actor_id: "actor",
        messages: [LittleGhost::Message.new(role: :user, content: "Stale")],
        state: {},
        metadata: {},
        expected_count: 0
      )
    end
  end

  private

  def filesystem_store
    LittleGhost::SessionStores::Filesystem.new(root: @root)
  end

  def snapshot_path
    Dir.glob(File.join(@root, "*.json")).fetch(0)
  end
end
