# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "async"
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
    assert_equal({"plan" => {"status" => "active"}}, snapshot.fetch(:state))
    assert_equal({"source" => "test"}, snapshot.fetch(:metadata))
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

  def test_canonicalizes_string_and_symbol_hash_keys
    filesystem_store.replace(
      "conversation",
      actor_id: "actor",
      messages: [],
      state: {"string" => {symbol: "value"}},
      metadata: {source: "test"}
    )

    snapshot = filesystem_store.load("conversation", actor_id: "actor")

    assert_equal({"string" => {"symbol" => "value"}}, snapshot.fetch(:state))
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
    document.fetch("snapshot").fetch("state").fetch("status").replace("changed")
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

    assert_equal({"status" => "original"}, store.load("conversation", actor_id: "actor").fetch(:state))
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

  def test_waiting_for_one_filesystem_lock_does_not_block_other_sessions
    store = filesystem_store
    lock_path = File.join(
      @root,
      "#{Digest::SHA256.hexdigest("little_ghost/filesystem_session/v1\0conversation")}.lock"
    )
    locked = Queue.new
    release = Queue.new
    owner = Thread.new do
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        locked << true
        release.pop
      end
    end
    locked.pop
    unrelated_completed_before_release = false

    Async do |task|
      waiting = task.async { store.load("conversation", actor_id: "actor") }
      assert_nil store.load("unrelated", actor_id: "actor")
      unrelated_completed_before_release = true
      release << true
      assert_nil waiting.wait
    end

    assert unrelated_completed_before_release
  ensure
    release << true if release && release.empty?
    owner&.join
  end

  def test_cancellation_keeps_the_filesystem_lock_until_the_transaction_finishes
    store = filesystem_store
    lock_path = File.join(
      @root,
      "#{Digest::SHA256.hexdigest("little_ghost/filesystem_session/v1\0conversation")}.lock"
    )
    started = Queue.new
    release = Queue.new
    retained_while_finishing = false

    Async do |task|
      store.stub(:write_snapshot, lambda { |_id, _snapshot|
        started << true
        release.pop
      }) do
        child = task.async do
          store.append(
            "conversation",
            actor_id: "actor",
            messages: [LittleGhost::Message.new(role: :user, content: "Hello")],
            state: {},
            metadata: {},
            expected_count: 0
          )
        end
        started.pop
        child.stop
        File.open(lock_path, File::RDWR) do |competitor|
          retained_while_finishing = !competitor.flock(File::LOCK_EX | File::LOCK_NB)
        end
        release << true
        child.wait
      end
    end.wait

    assert retained_while_finishing
    File.open(lock_path, File::RDWR) do |competitor|
      assert competitor.flock(File::LOCK_EX | File::LOCK_NB)
    end
  ensure
    release&.push(true)
  end

  def test_waiting_for_worker_capacity_does_not_hold_the_filesystem_lock
    store = filesystem_store
    lock_path = File.join(
      @root,
      "#{Digest::SHA256.hexdigest("little_ghost/filesystem_session/v1\0conversation")}.lock"
    )
    File.open(lock_path, File::RDWR | File::CREAT, 0o600, &:close)
    entered = Queue.new
    release = Queue.new
    lock_available = false

    Async do |task|
      workers = 4.times.map do
        task.async do
          LittleGhost::Support::BlockingOperation.call(lane: :filesystem) do
            entered << true
            release.pop
          end
        end
      end
      4.times { entered.pop }
      waiting = task.async { store.load("conversation", actor_id: "actor") }
      sleep(0.02)
      File.open(lock_path, File::RDWR) do |competitor|
        lock_available = competitor.flock(File::LOCK_EX | File::LOCK_NB)
      end
      4.times { release << true }
      workers.each(&:wait)
      assert_nil waiting.wait
    end.wait

    assert lock_available
  ensure
    4.times { release&.push(true) }
  end

  private

  def filesystem_store
    LittleGhost::SessionStores::Filesystem.new(root: @root)
  end

  def snapshot_path
    Dir.glob(File.join(@root, "*.json")).fetch(0)
  end
end
