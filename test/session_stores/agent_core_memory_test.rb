# frozen_string_literal: true

require "test_helper"
require "little_ghost/session_stores/agent_core_memory"

class AgentCoreMemoryTest < Minitest::Test
  Content = Struct.new(:text)
  Conversational = Struct.new(:role, :content)
  Payload = Struct.new(:conversational, :blob)
  Event = Struct.new(:event_timestamp, :payload, :metadata)
  Response = Struct.new(:events, :next_token)

  class Client
    attr_reader :created, :events, :listed

    def initialize(events = [])
      @events = events.dup
      @event_scopes = {}
      @created = []
      @listed = []
    end

    def list_events(**parameters)
      @listed << parameters
      events = @events.select do |event|
        scope = @event_scopes[event.object_id]
        in_scope = !scope || %i[memory_id actor_id session_id].all? do |key|
          scope.fetch(key) == parameters.fetch(key)
        end
        in_scope && Array(parameters.dig(:filter, :event_metadata)).all? do |expression|
          key = expression.dig(:left, :metadata_key)
          expected = expression.dig(:right, :metadata_value, :string_value)
          actual = event.metadata&.dig(key)
          actual = actual[:string_value] || actual["string_value"] if actual.is_a?(Hash)
          actual == expected
        end
      end
      offset = Integer(parameters.fetch(:next_token, 0))
      limit = parameters.fetch(:max_results)
      page = events.slice(offset, limit) || []
      next_token = (offset + page.length < events.length) ? String(offset + page.length) : nil
      Response.new(page, next_token)
    end

    def create_event(**parameters)
      @created << parameters
      event = self.class.events_from([parameters]).first
      @events << event
      @event_scopes[event.object_id] = parameters.slice(:memory_id, :actor_id, :session_id)
    end

    def self.events_from(created)
      created.each_with_index.map do |parameters, index|
        payloads = parameters.fetch(:payload).map do |payload|
          Payload.new(
            payload[:conversational] && Conversational.new(
              payload.dig(:conversational, :role),
              Content.new(payload.dig(:conversational, :content, :text))
            ),
            payload[:blob]
          )
        end
        Event.new(parameters[:event_timestamp] || Time.at(index + 1), payloads, parameters[:metadata])
      end
    end
  end

  def test_requires_memory_and_actor_ids
    assert_raises(ArgumentError) do
      LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "", client: Client.new)
    end

    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: Client.new)

    assert_raises(LittleGhost::ConfigurationError) { store.load("session") }
    assert_raises(LittleGhost::ConfigurationError) do
      store.replace("session", messages: [], state: {}, metadata: {})
    end
  end

  def test_loads_canonical_events_and_appends_only_new_messages
    seed_client = Client.new
    seed = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: seed_client)
    seed.replace(
      "session-id",
      actor_id: "actor-id",
      messages: [
        LittleGhost::Message.new(role: :user, content: "hi"),
        LittleGhost::Message.new(role: :assistant, content: "hello")
      ],
      state: {},
      metadata: {}
    )
    events = events_from(seed_client.created)
    client = Client.new(events)
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)

    snapshot = store.load("session-id", actor_id: "actor-id")
    store.append(
      "session-id",
      actor_id: "actor-id",
      messages: [LittleGhost::Message.new(role: :user, content: "again")],
      expected_count: 2,
      state: {step: 1},
      metadata: {source: "test"}
    )

    assert_equal %w[hi hello], snapshot.fetch(:messages).map(&:text)
    assert_equal 2, client.created.length
    assert_equal "USER", client.created.first.dig(:payload, 0, :conversational, :role)
    assert_equal(
      {string_value: LittleGhost::SessionStores::AgentCoreMemory::MESSAGE_EVENT_TYPE},
      client.created.first.dig(:metadata, LittleGhost::SessionStores::AgentCoreMemory::EVENT_TYPE_METADATA_KEY)
    )
    persisted = client.created.first.dig(:payload, 0, :conversational, :content, :text)
    assert persisted.start_with?(LittleGhost::SessionStores::AgentCoreMemory::MESSAGE_PREFIX)
    assert_includes persisted, "again"
    checkpoint = checkpoint_from(client.created.last)
    assert_instance_of String, client.created.last.dig(:payload, 0, :blob)
    assert_equal 3, checkpoint.fetch("message_count")
    assert_equal({step: 1}, checkpoint.fetch("state"))
    assert_equal({source: "test"}, checkpoint.fetch("metadata"))
    assert_operator checkpoint.fetch("serialized_bytes"), :>, 0
    assert(client.listed.all? do |parameters|
      parameters.fetch(:max_results) == LittleGhost::SessionStores::AgentCoreMemory::LIST_PAGE_SIZE
    end)
  end

  def test_rejects_non_little_ghost_session_events
    seed_client = Client.new
    LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: seed_client).replace(
      "session-id",
      actor_id: "actor-id",
      messages: [LittleGhost::Message.new(role: :user, content: "valid")],
      state: {},
      metadata: {}
    )
    events = events_from(seed_client.created)
    events.first.payload.first.conversational.content.text = "legacy message"
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: Client.new(events))

    error = assert_raises(LittleGhost::ProtocolError) do
      store.load("session-id", actor_id: "actor-id")
    end

    assert_includes error.message, "not a LittleGhost event"
  end

  def test_returns_nil_for_an_empty_session
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: Client.new)

    assert_nil store.load("new", actor_id: "actor")
  end

  def test_ignores_events_from_older_wire_protocols
    old_event = Event.new(
      Time.at(1),
      [Payload.new(nil, "little_ghost:checkpoint:v3:{}")],
      {
        LittleGhost::SessionStores::AgentCoreMemory::EVENT_TYPE_METADATA_KEY => {
          string_value: "checkpoint"
        }
      }
    )
    store = store_for(Client.new([old_event]))

    assert_nil store.load("session", actor_id: "actor")
  end

  def test_hashes_all_transport_identifiers_into_one_non_colliding_namespace
    klass = LittleGhost::SessionStores::AgentCoreMemory
    digest = Digest::SHA256.hexdigest("victim/id")

    refute_equal klass.safe_id("victim/id"), klass.safe_id("lg_#{digest}")
    assert_match(/\Alg_[a-f0-9]{64}\z/, klass.safe_id("safe-id"))

    client = Client.new
    store = klass.new(memory_id: "memory", client:)
    store.replace(
      "session/id",
      actor_id: "actor/id",
      messages: [LittleGhost::Message.new(role: :user, content: "hello")],
      state: {},
      metadata: {}
    )

    created = client.created.first
    assert_match(/\Alg_[a-f0-9]{64}\z/, created.fetch(:actor_id))
    assert_match(/\Alg_[a-f0-9]{64}\z/, created.fetch(:session_id))
    refute_equal created.fetch(:actor_id), created.fetch(:session_id)
  end

  def test_keeps_persistence_state_separate_for_each_actor
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)

    %w[first second].each do |actor_id|
      store.replace(
        "session",
        actor_id:,
        messages: [LittleGhost::Message.new(role: :user, content: actor_id)],
        state: {},
        metadata: {}
      )
    end

    conversational = client.created.filter_map { |event| event.dig(:payload, 0, :conversational) }
    assert_equal 2, conversational.length
    assert_equal 2, client.created.map { |event| event.fetch(:actor_id) }.uniq.length
  end

  def test_refreshes_remote_checkpoint_before_every_append
    client = Client.new
    first = store_for(client)
    second = store_for(client)
    first.replace("session", actor_id: "actor", messages: [user_message("seed")], state: {}, metadata: {})
    first.load("session", actor_id: "actor")
    second.append(
      "session",
      actor_id: "actor",
      messages: [user_message("external")],
      expected_count: 1,
      state: {},
      metadata: {}
    )

    assert_raises(LittleGhost::ProtocolError) do
      first.append(
        "session",
        actor_id: "actor",
        messages: [user_message("stale")],
        expected_count: 1,
        state: {},
        metadata: {}
      )
    end
  end

  def test_replacement_checkpoint_supersedes_the_previous_generation
    seed_client = Client.new
    seed = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: seed_client,
      clock: -> { Time.at(10) }
    )
    original = 6.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "old-#{index}")
    end
    seed.replace("session", actor_id: "actor", messages: original, state: {}, metadata: {})
    original_events = events_from(seed_client.created)

    client = Client.new(original_events)
    store = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client:,
      clock: -> { Time.at(100) }
    )
    session = LittleGhost::Session.new(id: "session", actor_id: "actor", store:)
    assert_equal original.map(&:to_h), session.history.map(&:to_h)

    compacted = [
      LittleGhost::Message.new(role: :user, content: "Summary of old-0 through old-3"),
      *original.last(2),
      LittleGhost::Message.new(role: :user, content: "new request"),
      LittleGhost::Message.new(role: :assistant, content: "new response")
    ]
    session.checkpoint(messages: compacted, state: {compacted: true})
    replacement = checkpoint_from(client.created.last)

    assert_equal checkpoint_from(seed_client.created.last).fetch("commit_id"), replacement.fetch("parent_commit_id")
    assert_equal 2, replacement.fetch("revision")

    load_client = Client.new([*original_events, *events_from(client.created)])
    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: load_client
    ).load("session", actor_id: "actor")

    assert_equal compacted.map(&:to_h), loaded.fetch(:messages).map(&:to_h)
    assert_equal({compacted: true}, loaded.fetch(:state))
    filters = load_client.listed.map { |parameters| parameters.dig(:filter, :event_metadata) }
    assert_equal [
      LittleGhost::SessionStores::AgentCoreMemory::CHECKPOINT_EVENT_TYPE,
      LittleGhost::SessionStores::AgentCoreMemory::MESSAGE_EVENT_TYPE
    ], filters.map { |expressions| expressions.first.dig(:right, :metadata_value, :string_value) }
    generation_filter = filters.last.find do |expression|
      expression.dig(:left, :metadata_key) == LittleGhost::SessionStores::AgentCoreMemory::GENERATION_METADATA_KEY
    end
    assert_equal(
      client.created.last.dig(
        :metadata,
        LittleGhost::SessionStores::AgentCoreMemory::GENERATION_METADATA_KEY,
        :string_value
      ),
      generation_filter.dig(:right, :metadata_value, :string_value)
    )
  end

  def test_uncommitted_replacement_messages_are_ignored
    client = Client.new
    client.define_singleton_method(:create_event) do |**parameters|
      raise "checkpoint unavailable" if parameters.dig(:payload, 0, :blob)

      @created << parameters
    end
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)

    assert_raises(RuntimeError) do
      store.replace(
        "session",
        actor_id: "actor",
        messages: [LittleGhost::Message.new(role: :user, content: "not committed")],
        state: {},
        metadata: {}
      )
    end

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new(events_from(client.created))
    ).load("session", actor_id: "actor")
    assert_nil loaded
  end

  def test_retries_an_append_after_messages_persist_but_the_checkpoint_fails
    client = Client.new
    store = store_for(client, clock: -> { Time.at(100) })
    store.replace("session", actor_id: "actor", messages: [user_message("seed")], state: {}, metadata: {})
    fail_next_checkpoint(client)

    assert_raises(RuntimeError) do
      store.append(
        "session",
        actor_id: "actor",
        messages: [user_message("retry")],
        expected_count: 1,
        state: {attempt: 1},
        metadata: {}
      )
    end
    store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("retry")],
      expected_count: 1,
      state: {attempt: 2},
      metadata: {}
    )

    loaded = store.load("session", actor_id: "actor")
    assert_equal %w[seed retry], loaded.fetch(:messages).map(&:text)
    assert_equal({attempt: 2}, loaded.fetch(:state))
  end

  def test_can_retry_different_messages_after_an_uncommitted_append
    client = Client.new
    store = store_for(client)
    store.replace("session", actor_id: "actor", messages: [user_message("seed")], state: {}, metadata: {})
    fail_next_checkpoint(client)

    assert_raises(RuntimeError) do
      store.append(
        "session",
        actor_id: "actor",
        messages: [user_message("abandoned")],
        expected_count: 1,
        state: {},
        metadata: {}
      )
    end
    store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("committed")],
      expected_count: 1,
      state: {},
      metadata: {}
    )

    assert_equal %w[seed committed], store.load("session", actor_id: "actor").fetch(:messages).map(&:text)
  end

  def test_treats_a_persisted_checkpoint_as_committed_when_the_response_fails
    client = Client.new
    store = store_for(client)
    store.replace("session", actor_id: "actor", messages: [user_message("seed")], state: {}, metadata: {})
    original = client.method(:create_event)
    failed = false
    client.define_singleton_method(:create_event) do |**parameters|
      original.call(**parameters)
      if !failed && parameters.dig(:payload, 0, :blob)
        failed = true
        raise "checkpoint response lost"
      end
    end

    assert_raises(RuntimeError) do
      store.append(
        "session",
        actor_id: "actor",
        messages: [user_message("committed")],
        expected_count: 1,
        state: {},
        metadata: {}
      )
    end
    assert_equal %w[seed committed], store.load("session", actor_id: "actor").fetch(:messages).map(&:text)
    assert_raises(LittleGhost::ProtocolError) do
      store.append(
        "session",
        actor_id: "actor",
        messages: [user_message("duplicate")],
        expected_count: 1,
        state: {},
        metadata: {}
      )
    end
  end

  def test_resolves_equal_timestamp_concurrent_forks_deterministically
    seed_client = Client.new
    store_for(seed_client, clock: -> { Time.at(100) }).replace(
      "session",
      actor_id: "actor",
      messages: [user_message("seed")],
      state: {},
      metadata: {}
    )
    seed_events = events_from(seed_client.created)
    left_client = Client.new(seed_events)
    right_client = Client.new(events_from(seed_client.created))
    store_for(left_client, clock: -> { Time.at(100) }).append(
      "session",
      actor_id: "actor",
      messages: [user_message("left")],
      expected_count: 1,
      state: {branch: "left"},
      metadata: {}
    )
    store_for(right_client, clock: -> { Time.at(100) }).append(
      "session",
      actor_id: "actor",
      messages: [user_message("right")],
      expected_count: 1,
      state: {branch: "right"},
      metadata: {}
    )

    left_checkpoint = checkpoint_from(left_client.created.last)
    right_checkpoint = checkpoint_from(right_client.created.last)
    assert_equal left_client.created.last.fetch(:event_timestamp), right_client.created.last.fetch(:event_timestamp)
    winner = [left_checkpoint, right_checkpoint].max_by { |checkpoint| checkpoint.fetch("commit_id") }
    events = [
      *seed_events,
      *events_from(left_client.created),
      *events_from(right_client.created)
    ]
    histories = [events, events.reverse].map do |ordered|
      store_for(Client.new(ordered)).load("session", actor_id: "actor")
    end

    expected_branch = winner.fetch("state").fetch(:branch)
    assert_equal [["seed", expected_branch], ["seed", expected_branch]],
      histories.map { |snapshot| snapshot.fetch(:messages).map(&:text) }
    assert_equal [expected_branch, expected_branch], histories.map { |snapshot| snapshot.dig(:state, :branch) }
  end

  def test_a_delayed_old_generation_writer_cannot_resurrect_replaced_history
    seed_client = Client.new
    store_for(seed_client, clock: -> { Time.at(100) }).replace(
      "session",
      actor_id: "actor",
      messages: [user_message("old")],
      state: {},
      metadata: {}
    )
    seed_events = events_from(seed_client.created)

    current_client = Client.new(seed_events)
    current_store = store_for(current_client, clock: -> { Time.at(100) })
    current_store.replace(
      "session",
      actor_id: "actor",
      messages: [user_message("replacement")],
      state: {},
      metadata: {}
    )
    current_store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("current")],
      expected_count: 1,
      state: {generation: "current"},
      metadata: {}
    )

    stale_client = Client.new(seed_events)
    stale_store = store_for(stale_client, clock: -> { Time.at(1_000) })
    stale_store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("stale")],
      expected_count: 1,
      state: {generation: "stale"},
      metadata: {}
    )
    stale_store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("stale-again")],
      expected_count: 2,
      state: {generation: "stale"},
      metadata: {}
    )

    snapshot = store_for(Client.new([
      *seed_events,
      *events_from(current_client.created),
      *events_from(stale_client.created)
    ])).load("session", actor_id: "actor")

    assert_equal %w[replacement current], snapshot.fetch(:messages).map(&:text)
    assert_equal "current", snapshot.dig(:state, :generation)
  end

  def test_rejects_an_initial_root_checkpoint_with_a_noninitial_revision
    client = Client.new
    store_for(client).replace("session", actor_id: "actor", messages: [], state: {}, metadata: {})
    events = events_from(client.created)
    checkpoint = checkpoint_from_event(events.last).merge("revision" => 999)
    events.last.payload.first.blob = checkpoint_blob(checkpoint)

    error = assert_raises(LittleGhost::ProtocolError) do
      store_for(Client.new(events)).load("session", actor_id: "actor")
    end

    assert_includes error.message, "root checkpoint"
  end

  def test_loads_a_replacement_root_after_its_superseded_checkpoint_expires
    client = Client.new
    store = store_for(client, clock: -> { Time.at(100) })
    store.replace("session", actor_id: "actor", messages: [user_message("old")], state: {}, metadata: {})
    client.created.clear
    store.replace(
      "session",
      actor_id: "actor",
      messages: [user_message("replacement")],
      state: {compacted: true},
      metadata: {}
    )

    snapshot = store_for(Client.new(events_from(client.created))).load("session", actor_id: "actor")

    assert_equal ["replacement"], snapshot.fetch(:messages).map(&:text)
    assert_equal({compacted: true}, snapshot.fetch(:state))
  end

  def test_ignores_an_obsolete_append_whose_parent_expired_before_a_replacement
    client = Client.new
    store = store_for(client, clock: -> { Time.at(100) })
    store.replace("session", actor_id: "actor", messages: [user_message("old")], state: {}, metadata: {})
    store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("old-append")],
      expected_count: 1,
      state: {},
      metadata: {}
    )
    store.replace(
      "session",
      actor_id: "actor",
      messages: [user_message("replacement")],
      state: {compacted: true},
      metadata: {}
    )
    events = events_from(client.created)
    first_checkpoint = events.find { |event| event.payload.first.blob }
    retained = events.reject { |event| event.equal?(first_checkpoint) }

    snapshot = store_for(Client.new(retained)).load("session", actor_id: "actor")

    assert_equal ["replacement"], snapshot.fetch(:messages).map(&:text)
    assert_equal({compacted: true}, snapshot.fetch(:state))
  end

  def test_returns_nil_when_only_an_unrecoverable_append_checkpoint_remains
    client = Client.new
    store = store_for(client)
    store.replace("session", actor_id: "actor", messages: [user_message("old")], state: {}, metadata: {})
    store.append(
      "session",
      actor_id: "actor",
      messages: [user_message("append")],
      expected_count: 1,
      state: {},
      metadata: {}
    )
    events = events_from(client.created)
    first_checkpoint = events.find { |event| event.payload.first.blob }

    assert_nil store_for(Client.new(events.reject { |event| event.equal?(first_checkpoint) })).load(
      "session",
      actor_id: "actor"
    )
  end

  def test_loads_a_deep_checkpoint_lineage_without_recursive_graph_traversal
    klass = LittleGhost::SessionStores::AgentCoreMemory
    generation = "generation"
    events = 1_500.times.map do |index|
      commit_id = "commit-#{index}"
      checkpoint = {
        "generation" => generation,
        "generation_revision" => 1,
        "commit_id" => commit_id,
        "parent_commit_id" => index.zero? ? nil : "commit-#{index - 1}",
        "revision" => index + 1,
        "root" => index.zero?,
        "start_sequence" => 0,
        "added_count" => 0,
        "message_count" => 0,
        "serialized_bytes" => 0,
        "event_count" => 0,
        "payload_count" => 0,
        "state" => {"depth" => index},
        "metadata" => {}
      }
      Event.new(
        Time.at(index + 1),
        [Payload.new(nil, checkpoint_blob(checkpoint))],
        event_metadata(klass::CHECKPOINT_EVENT_TYPE, generation, commit_id)
      )
    end

    snapshot = store_for(Client.new(events)).load("session", actor_id: "actor")

    assert_empty snapshot.fetch(:messages)
    assert_equal 1_499, snapshot.dig(:state, "depth")
  end

  def test_rejects_checkpoint_metadata_that_disagrees_with_its_blob
    klass = LittleGhost::SessionStores::AgentCoreMemory
    [klass::GENERATION_METADATA_KEY, klass::COMMIT_METADATA_KEY].each do |key|
      client = Client.new
      store_for(client).replace("session", actor_id: "actor", messages: [], state: {}, metadata: {})
      events = events_from(client.created)
      value = events.last.metadata.fetch(key).fetch(:string_value)
      events.last.metadata[key] = {string_value: "x" * value.length}

      error = assert_raises(LittleGhost::ProtocolError) do
        store_for(Client.new(events)).load("session", actor_id: "actor")
      end
      assert_includes error.message, "checkpoint metadata"
    end
  end

  def test_rejects_message_identity_that_disagrees_with_event_metadata
    klass = LittleGhost::SessionStores::AgentCoreMemory
    %w[generation commit_id].each do |field|
      client = Client.new
      store_for(client).replace(
        "session",
        actor_id: "actor",
        messages: [user_message("valid")],
        state: {},
        metadata: {}
      )
      events = events_from(client.created)
      text = events.first.payload.first.conversational.content.text
      record = JSON.parse(text.delete_prefix(klass::MESSAGE_PREFIX))
      record[field] = "x" * record.fetch(field).length
      events.first.payload.first.conversational.content.text = "#{klass::MESSAGE_PREFIX}#{JSON.generate(record)}"

      error = assert_raises(LittleGhost::ProtocolError) do
        store_for(Client.new(events)).load("session", actor_id: "actor")
      end
      assert_includes error.message, "message identity"
    end
  end

  def test_rejects_incomplete_selected_message_chunks_as_a_protocol_error
    client = Client.new
    store_for(client).replace(
      "session",
      actor_id: "actor",
      messages: [user_message("x" * 210_000)],
      state: {},
      metadata: {}
    )
    events = events_from(client.created)
    events.first.payload.pop

    error = assert_raises(LittleGhost::ProtocolError) do
      store_for(Client.new(events)).load("session", actor_id: "actor")
    end
    assert_includes error.message, "chunks are incomplete"
  end

  def test_checkpoint_byte_accounting_matches_the_exact_framed_payloads
    client = Client.new
    store = store_for(client)
    messages = [user_message("é" * 100_000), user_message("👻" * 20)]
    store.replace("session", actor_id: "actor", messages:, state: {}, metadata: {})

    message_events = client.created.select { |event| event.dig(:payload, 0, :conversational) }
    texts = message_events.flat_map do |event|
      event.fetch(:payload).map { |payload| payload.dig(:conversational, :content, :text) }
    end
    checkpoint = checkpoint_from(client.created.last)
    assert_equal texts.sum(&:bytesize), checkpoint.fetch("serialized_bytes")
    assert_equal message_events.length, checkpoint.fetch("event_count")
    assert_equal texts.length, checkpoint.fetch("payload_count")
    assert_equal messages.map(&:to_h), store.load("session", actor_id: "actor").fetch(:messages).map(&:to_h)
  end

  def test_incomplete_uncommitted_message_chunks_do_not_hide_the_last_checkpoint
    seed_client = Client.new
    seed = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: seed_client)
    seed.replace(
      "session",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "committed")],
      state: {},
      metadata: {}
    )
    events = events_from(seed_client.created)
    checkpoint = checkpoint_from(seed_client.created.last)
    incomplete = event_with_message(
      events.last.event_timestamp + 1,
      role: "USER",
      text: "#{LittleGhost::SessionStores::AgentCoreMemory::MESSAGE_CHUNK_PREFIX}orphan:0:0:2:{",
      metadata: event_metadata(
        LittleGhost::SessionStores::AgentCoreMemory::MESSAGE_EVENT_TYPE,
        checkpoint.fetch("generation"),
        "orphan"
      )
    )

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new([*events, incomplete])
    ).load("session", actor_id: "actor")

    assert_equal ["committed"], loaded.fetch(:messages).map(&:text)
  end

  def test_assigns_monotonic_whole_second_event_timestamps
    now = Time.at(1_000)
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client:,
      clock: -> { now }
    )

    store.replace(
      "session",
      actor_id: "actor",
      messages: [
        LittleGhost::Message.new(role: :user, content: "one"),
        LittleGhost::Message.new(role: :assistant, content: "two")
      ],
      state: {},
      metadata: {}
    )

    increment = LittleGhost::SessionStores::AgentCoreMemory::EVENT_TIMESTAMP_INCREMENT
    assert_equal [now, now + increment], client.created.map { |event| event.fetch(:event_timestamp) }
  end

  def test_new_writer_advances_past_the_latest_persisted_timestamp
    seed_client = Client.new
    seed = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: seed_client,
      clock: -> { Time.at(100) }
    )
    seed.replace(
      "session",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "first")],
      state: {},
      metadata: {}
    )
    events = events_from(seed_client.created)
    client = Client.new(events)
    store = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client:,
      clock: -> { Time.at(50) }
    )

    store.append(
      "session",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :assistant, content: "second")],
      expected_count: 1,
      state: {},
      metadata: {}
    )

    latest = events.last.event_timestamp
    increment = LittleGhost::SessionStores::AgentCoreMemory::EVENT_TIMESTAMP_INCREMENT
    assert_equal [latest + increment, latest + (increment * 2)], client.created.map { |event| event.fetch(:event_timestamp) }
  end

  def test_direct_replacement_advances_past_the_latest_persisted_timestamp
    seed_client = Client.new
    seed = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: seed_client,
      clock: -> { Time.at(100) }
    )
    seed.replace("session", actor_id: "actor", messages: [], state: {}, metadata: {})
    events = events_from(seed_client.created)
    client = Client.new(events)
    store = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client:,
      clock: -> { Time.at(50) }
    )

    store.replace("session", actor_id: "actor", messages: [], state: {replaced: true}, metadata: {})

    increment = LittleGhost::SessionStores::AgentCoreMemory::EVENT_TIMESTAMP_INCREMENT
    assert_equal events.last.event_timestamp + increment, client.created.first.fetch(:event_timestamp)
  end

  def test_message_sequences_preserve_order_when_service_timestamps_tie
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)
    store.replace(
      "session",
      actor_id: "actor",
      messages: [
        LittleGhost::Message.new(role: :user, content: "first"),
        LittleGhost::Message.new(role: :assistant, content: "second")
      ],
      state: {},
      metadata: {}
    )
    events = events_from(client.created)
    message_event = events.first
    tied_messages = Event.new(Time.at(1), message_event.payload.reverse, message_event.metadata)
    checkpoint = Event.new(Time.at(2), events.last.payload, events.last.metadata)

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new([tied_messages, checkpoint])
    ).load("session", actor_id: "actor")

    assert_equal %w[first second], loaded.fetch(:messages).map(&:text)
  end

  def test_round_trips_canonical_messages_without_persisting_private_reasoning
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)
    messages = [
      LittleGhost::Message.new(role: :assistant, content: [
        LittleGhost::Content::Reasoning.new(text: "thinking"),
        LittleGhost::Content::ToolUse.new(id: "call-1", name: "search", input: {"query" => false})
      ]),
      LittleGhost::Message.new(
        role: :tool,
        content: LittleGhost::Content::ToolResult.new(
          tool_use_id: "call-1",
          content: [LittleGhost::Content::Text.new(text: "found")],
          status: :success
        )
      ),
      LittleGhost::Message.new(
        role: :user,
        content: LittleGhost::Content::Image.new(data: "\x00\xFF".b, media_type: "image/png")
      )
    ]
    store.replace("session", actor_id: "actor", messages:, state: {}, metadata: {})

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new(events_from(client.created))
    ).load("session", actor_id: "actor")

    expected_content = [
      [LittleGhost::Content::ToolUse.new(id: "call-1", name: "search", input: {"query" => false})],
      messages.fetch(1).content,
      messages.fetch(2).content
    ]
    assert_equal messages.map(&:role), loaded.fetch(:messages).map(&:role)
    assert_equal expected_content, loaded.fetch(:messages).map(&:content)
    refute_includes client.created.to_s, "thinking"
  end

  def test_chunks_messages_larger_than_agent_core_conversational_text
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)
    message = LittleGhost::Message.new(role: :user, content: "x" * 210_000)

    store.replace("session", actor_id: "actor", messages: [message], state: {}, metadata: {})

    conversational = client.created.flat_map do |event|
      event.fetch(:payload).filter_map { |payload| payload[:conversational] }
    end
    assert_operator conversational.length, :>, 1
    assert(conversational.all? do |payload|
      payload.dig(:content, :text).bytesize <= LittleGhost::SessionStores::AgentCoreMemory::CONVERSATIONAL_TEXT_LIMIT
    end)

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new(events_from(client.created))
    ).load("session", actor_id: "actor")

    assert_equal message.to_h, loaded.fetch(:messages).first.to_h
  end

  def test_uses_agent_core_character_limits_for_multibyte_messages
    client = Client.new
    store = store_for(client)
    message = user_message("👻" * 30_000)

    store.replace("session", actor_id: "actor", messages: [message], state: {}, metadata: {})

    texts = client.created.flat_map do |event|
      event.fetch(:payload).filter_map { |payload| payload.dig(:conversational, :content, :text) }
    end
    assert_equal 1, texts.length
    assert texts.first.valid_encoding?
    assert_operator texts.first.bytesize, :>, LittleGhost::SessionStores::AgentCoreMemory::CONVERSATIONAL_TEXT_LIMIT
    assert_operator texts.first.length, :<=, LittleGhost::SessionStores::AgentCoreMemory::CONVERSATIONAL_TEXT_LIMIT
    assert_equal message.to_h, store.load("session", actor_id: "actor").fetch(:messages).first.to_h
  end

  def test_batches_messages_with_different_roles_into_one_create_event
    client = Client.new
    store = store_for(client)
    messages = 12.times.map do |index|
      LittleGhost::Message.new(role: index.even? ? :user : :assistant, content: "message-#{index}")
    end

    store.replace("session", actor_id: "actor", messages:, state: {}, metadata: {})

    message_events = client.created.select { |event| event.dig(:payload, 0, :conversational) }
    assert_equal 1, message_events.length
    assert_equal 12, message_events.first.fetch(:payload).length
    assert_equal %w[USER ASSISTANT] * 6,
      message_events.first.fetch(:payload).map { |payload| payload.dig(:conversational, :role) }
    assert_equal messages.map(&:to_h), store.load("session", actor_id: "actor").fetch(:messages).map(&:to_h)
  end

  def test_round_trips_session_state_and_metadata
    client = Client.new
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)
    store.replace(
      "session",
      actor_id: "actor",
      messages: [],
      state: {"plan" => ["ship"]},
      metadata: {"source" => "test"}
    )

    loaded = LittleGhost::SessionStores::AgentCoreMemory.new(
      memory_id: "memory",
      client: Client.new(events_from(client.created))
    ).load("session", actor_id: "actor")

    assert_equal({"plan" => ["ship"]}, loaded.fetch(:state))
    assert_equal({"source" => "test"}, loaded.fetch(:metadata))
  end

  def test_bounds_events_payloads_and_serialized_bytes_while_loading
    events = [
      event_with_message(Time.at(1), role: "USER", text: "one"),
      event_with_message(Time.at(2), role: "USER", text: "two")
    ]
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: Client.new(events))

    assert_raises(LittleGhost::ProtocolError) do
      store.send(
        :each_event,
        "actor",
        "session",
        filter: {},
        event_limit: 1,
        payload_limit: 10,
        byte_limit: 100
      ) { nil }
    end
    assert_raises(LittleGhost::ProtocolError) do
      store.send(
        :each_event,
        "actor",
        "session",
        filter: {},
        event_limit: 10,
        payload_limit: 10,
        byte_limit: 5
      ) { nil }
    end

    multipayload = Event.new(Time.at(1), [
      Payload.new(Conversational.new("USER", Content.new("one")), nil),
      Payload.new(Conversational.new("USER", Content.new("two")), nil)
    ])
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client: Client.new([multipayload]))
    assert_raises(LittleGhost::ProtocolError) do
      store.send(
        :each_event,
        "actor",
        "session",
        filter: {},
        event_limit: 10,
        payload_limit: 1,
        byte_limit: 100
      ) { nil }
    end
  end

  def test_rejects_malformed_conversational_envelopes_as_protocol_errors
    malformed = Event.new(Time.at(1), [Payload.new(Conversational.new("USER", nil), nil)])
    store = store_for(Client.new([malformed]))

    error = assert_raises(LittleGhost::ProtocolError) do
      store.send(
        :each_event,
        "actor",
        "session",
        filter: {},
        event_limit: 10,
        payload_limit: 10,
        byte_limit: 100
      ) { nil }
    end

    assert_includes error.message, "conversational payload"
  end

  def test_rejects_repeated_agent_core_pagination_tokens
    client = Client.new
    client.define_singleton_method(:list_events) do |**|
      Response.new([], "same")
    end
    store = LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:)

    error = assert_raises(LittleGhost::ProtocolError) do
      store.send(
        :each_event,
        "actor",
        "session",
        filter: {},
        event_limit: 10,
        payload_limit: 10,
        byte_limit: 100
      ) { nil }
    end
    assert_includes error.message, "pagination token"
  end

  def test_rejects_oversized_messages_sessions_and_checkpoints
    klass = LittleGhost::SessionStores::AgentCoreMemory
    client = Client.new
    store = klass.new(memory_id: "memory", client:)

    oversized = LittleGhost::Message.new(
      role: :user,
      content: "x" * (klass::MAX_MESSAGE_SERIALIZED_BYTES + 1)
    )
    assert_raises(LittleGhost::ProtocolError) do
      store.replace("session", actor_id: "actor", messages: [oversized], state: {}, metadata: {})
    end
    assert_raises(LittleGhost::ProtocolError) do
      store.send(:validate_session_size!, klass::MAX_SESSION_MESSAGES + 1, 0)
    end
    assert_raises(LittleGhost::ProtocolError) do
      store.send(:validate_session_size!, 0, klass::MAX_SESSION_SERIALIZED_BYTES + 1)
    end
    assert_raises(LittleGhost::ProtocolError) do
      store.replace(
        "session",
        actor_id: "actor",
        messages: [],
        state: {value: "x" * klass::MAX_CHECKPOINT_SERIALIZED_BYTES},
        metadata: {}
      )
    end
    assert_empty client.created
  end

  def test_rejects_oversized_chunk_accumulation_before_joining
    klass = LittleGhost::SessionStores::AgentCoreMemory
    store = store_for(Client.new)
    chunks = {}
    content = "x" * ((klass::MAX_MESSAGE_SERIALIZED_BYTES / 2) + 1)
    prefix = klass::MESSAGE_CHUNK_PREFIX

    store.send(:record_message_chunk, "#{prefix}commit:0:0:2:#{content}", chunks, commit_id: "commit")
    assert_raises(LittleGhost::ProtocolError) do
      store.send(:record_message_chunk, "#{prefix}commit:0:1:2:#{content}", chunks, commit_id: "commit")
    end
  end

  def test_rejects_oversized_checkpoints_while_loading
    klass = LittleGhost::SessionStores::AgentCoreMemory
    client = Client.new
    store = store_for(client)
    store.replace("session", actor_id: "actor", messages: [], state: {}, metadata: {})
    checkpoint = checkpoint_from(client.created.last).merge(
      "state" => {"large" => "x" * klass::MAX_CHECKPOINT_SERIALIZED_BYTES}
    )

    assert_raises(LittleGhost::ProtocolError) do
      store.send(:normalize_checkpoint, checkpoint)
    end
  end

  def test_rejects_scalar_message_records_as_protocol_errors
    store = store_for(Client.new)

    ["42", JSON.generate("scalar"), JSON.generate("message" => 42)].each do |value|
      assert_raises(LittleGhost::ProtocolError) do
        store.send(:decode_message_record, value)
      end
    end
  end

  private

  def checkpoint_from(created_event)
    checkpoint_from_blob(created_event.dig(:payload, 0, :blob))
  end

  def checkpoint_from_event(event)
    checkpoint_from_blob(event.payload.first.blob)
  end

  def checkpoint_from_blob(blob)
    prefix = LittleGhost::SessionStores::AgentCoreMemory::CHECKPOINT_PREFIX
    store_for(Client.new).send(:deserialize_checkpoint, blob.delete_prefix(prefix))
  end

  def checkpoint_blob(checkpoint)
    store = store_for(Client.new)
    "#{LittleGhost::SessionStores::AgentCoreMemory::CHECKPOINT_PREFIX}" \
      "#{store.send(:serialize_checkpoint, checkpoint)}"
  end

  def event_metadata(type, generation, commit_id)
    klass = LittleGhost::SessionStores::AgentCoreMemory
    {
      klass::EVENT_TYPE_METADATA_KEY => {string_value: type},
      klass::GENERATION_METADATA_KEY => {string_value: generation},
      klass::COMMIT_METADATA_KEY => {string_value: commit_id}
    }
  end

  def event_with_message(timestamp, role:, text:, metadata: nil)
    Event.new(timestamp, [Payload.new(Conversational.new(role, Content.new(text)), nil)], metadata)
  end

  def events_from(created)
    Client.events_from(created)
  end

  def fail_next_checkpoint(client)
    original = client.method(:create_event)
    failed = false
    client.define_singleton_method(:create_event) do |**parameters|
      if !failed && parameters.dig(:payload, 0, :blob)
        failed = true
        raise "checkpoint unavailable"
      end

      original.call(**parameters)
    end
  end

  def user_message(text)
    LittleGhost::Message.new(role: :user, content: text)
  end

  def store_for(client, clock: -> { Time.now })
    LittleGhost::SessionStores::AgentCoreMemory.new(memory_id: "memory", client:, clock:)
  end
end
