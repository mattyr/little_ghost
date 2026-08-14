# frozen_string_literal: true

module LittleGhost
  # Sessions let an agent continue a conversation without tying it to one Ruby
  # process. Each session keeps messages, application state, and metadata
  # together behind a SessionStore.
  #
  #   session = LittleGhost::Session.new(
  #     id: "conversation-42",
  #     actor_id: "user-7",
  #     store: LittleGhost::SessionStores::Memory.new
  #   )
  #   session.append(
  #     messages: [LittleGhost::Message.new(role: :user, content: "Hello")],
  #     state: {language: "en"}
  #   )
  #
  #   reopened = LittleGhost::Session.new(
  #     id: "conversation-42",
  #     actor_id: "user-7",
  #     store: session.store
  #   )
  #   reopened.history.last.text # => "Hello"
  #   reopened.state[:language]  # => "en"
  #
  # === Persistence and trust
  #
  # System messages, transient messages, and private model reasoning are removed
  # before persistence. Store failures reach the caller; a successful write is
  # the checkpoint boundary.
  #
  # Multi-tenant applications must derive +actor_id+ from stable, authenticated
  # identity. A nil actor provides no tenant isolation and is appropriate only
  # for a store that serves one actor.
  class Session
    # The store key, explicit actor identity, backing store, and telemetry
    # operation used by this session.
    attr_reader :id, :actor_id, :store, :operation_id

    # No store access occurs until the session is read or written.
    def initialize(id:, store:, actor_id: nil, metadata: {}, operation_id: nil)
      @id = String(id)
      @actor_id = actor_id&.to_s
      @store = store
      @operation_id = operation_id
      @metadata = DataMap.new(metadata).freeze
      @loaded = false
    end

    # Loads and normalizes the snapshot once. A new session has no snapshot.
    def load
      return @snapshot if @loaded

      value = with_store_operation_context { store.load(id, actor_id:) }
      @snapshot = normalize(value)
      @loaded = true
      @snapshot
    end

    # Uses persisted conversation messages when present and +fallback+ for a new
    # session.
    def history(fallback: [])
      load&.fetch(:messages) || fallback
    end

    # Exposes a mutable DataMap copy of the persisted application state. String
    # and Symbol keys address the same value; persisted snapshots use Strings.
    def state
      snapshot = load
      DataMap.new(snapshot ? snapshot.fetch(:state) : {})
    end

    # Uses persisted metadata when present and otherwise keeps the metadata from
    # construction. The returned DataMap is frozen.
    def metadata
      loaded = load
      loaded ? DataMap.new(loaded.fetch(:metadata)).freeze : @metadata
    end

    # Atomically appends +messages+ when the store still has the expected
    # history length. Prefer #checkpoint when replacing earlier messages is
    # also valid.
    def append(messages:, state: self.state, metadata: self.metadata)
      current = current_snapshot
      added = persistable_messages(messages)
      snapshot = build_snapshot(
        messages: [*current.fetch(:messages), *added],
        state:,
        metadata:
      )
      with_store_operation_context do
        store.append(
          id,
          messages: added,
          state: snapshot.fetch(:state),
          metadata: snapshot.fetch(:metadata),
          expected_count: current.fetch(:messages).length,
          actor_id:
        )
      end
      remember(snapshot)
    end

    # Replaces the complete persisted snapshot.
    def replace(messages:, state: self.state, metadata: self.metadata)
      snapshot = build_snapshot(messages:, state:, metadata:)
      with_store_operation_context { store.replace(id, actor_id:, **snapshot) }
      remember(snapshot)
    end

    # Persists one conversation checkpoint. History is appended when the stored
    # messages are an unchanged prefix and replaced otherwise.
    def checkpoint(messages:, state: self.state, metadata: self.metadata, parent_operation_id: @operation_id)
      with_store_operation_context(parent_operation_id) do
        snapshot = build_snapshot(messages:, state:, metadata:)
        current = current_snapshot
        if message_prefix?(current.fetch(:messages), snapshot.fetch(:messages))
          added = snapshot.fetch(:messages).drop(current.fetch(:messages).length)
          unless added.empty? && same_session_data?(current, snapshot)
            store.append(
              id,
              messages: added,
              state: snapshot.fetch(:state),
              metadata: snapshot.fetch(:metadata),
              expected_count: current.fetch(:messages).length,
              actor_id:
            )
          end
        else
          store.replace(id, actor_id:, **snapshot)
        end
        remember(snapshot)
      end
    end

    # Checkpoints the messages and state from a completed run result.
    def checkpoint_result(result)
      checkpoint(messages: result.messages, state: result.state)
    end

    # Serializes work for this session and actor through the backing store.
    def synchronize(&block)
      store.synchronize(id, actor_id:, &block)
    end

    # Publishes a conversational view without changing the session's stored
    # transcript. Unlike session persistence, projection does not automatically
    # remove system or transient messages; callers must omit any message whose
    # visible text should stay local. Stores that do not support projections
    # return nil.
    def project_conversation(messages:, metadata: self.metadata)
      with_store_operation_context do
        store.project_conversation(id, messages:, metadata:, actor_id:)
      end
    end

    private

    def current_snapshot
      load || build_snapshot(messages: [], state: {}, metadata: @metadata)
    end

    def with_store_operation_context(operation_id = @operation_id)
      store.with_operation_context(operation_id) { yield }
    end

    def build_snapshot(messages:, state:, metadata:)
      {
        messages: persistable_messages(messages),
        state: DataMap.new(state).to_h,
        metadata: DataMap.new(metadata).to_h
      }.freeze
    end

    def remember(snapshot)
      @snapshot = snapshot
      @loaded = true
      snapshot
    end

    def message_prefix?(current, candidate)
      return false if current.length > candidate.length

      current.each_with_index.all? do |message, index|
        message.to_h == candidate.fetch(index).to_h
      end
    end

    def same_session_data?(left, right)
      left.fetch(:state) == right.fetch(:state) && left.fetch(:metadata) == right.fetch(:metadata)
    end

    def normalize(value)
      return unless value

      {
        messages: persistable_messages(Array(value.fetch(:messages))),
        state: DataMap.new(value.fetch(:state, {})).to_h,
        metadata: DataMap.new(value.fetch(:metadata, {})).to_h
      }.freeze
    rescue KeyError, NoMethodError, TypeError => error
      raise ProtocolError, "Session store returned an invalid value: #{error.class}"
    end

    def persistable_messages(messages)
      messages.filter_map do |value|
        message = Message.coerce(value)
        next if message.role == :system
        next if message.metadata[:transient] || message.metadata["transient"]

        sanitized = message.without_reasoning
        next if sanitized.content.empty? && !message.content.empty?

        sanitized
      end.freeze
    end
  end
end
