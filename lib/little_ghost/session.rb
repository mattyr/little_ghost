# frozen_string_literal: true

module LittleGhost
  class Session
    attr_reader :id, :actor_id, :store, :operation_id

    def initialize(id:, store:, actor_id: nil, metadata: {}, operation_id: nil)
      @id = String(id)
      @actor_id = actor_id&.to_s
      @store = store
      @operation_id = operation_id
      @metadata = metadata.to_h.freeze
      @loaded = false
    end

    def load
      return @snapshot if @loaded

      value = with_store_operation_context { store.load(id, actor_id:) }
      @snapshot = normalize(value)
      @loaded = true
      @snapshot
    end

    def history(fallback: [])
      load&.fetch(:messages) || fallback
    end

    def state
      snapshot = load
      snapshot ? mutable_copy(snapshot.fetch(:state)) : {}
    end

    def metadata
      load&.fetch(:metadata) || @metadata
    end

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

    def replace(messages:, state: self.state, metadata: self.metadata)
      snapshot = build_snapshot(messages:, state:, metadata:)
      with_store_operation_context { store.replace(id, actor_id:, **snapshot) }
      remember(snapshot)
    end

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

    def checkpoint_result(result)
      checkpoint(messages: result.messages, state: result.state)
    end

    def synchronize(&block)
      store.synchronize(id, actor_id:, &block)
    end

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
        state: Support.deep_dup(state.to_h),
        metadata: Support.deep_dup(metadata.to_h)
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
        state: Support.deep_dup(value.fetch(:state, {}).to_h),
        metadata: Support.deep_dup(value.fetch(:metadata, {}).to_h)
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

    def mutable_copy(value)
      case value
      when Hash
        value.to_h { |key, child| [mutable_copy(key), mutable_copy(child)] }
      when Array
        value.map { |child| mutable_copy(child) }
      when String
        value.dup
      else
        value
      end
    end
  end
end
