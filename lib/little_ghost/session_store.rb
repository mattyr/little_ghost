# frozen_string_literal: true

module LittleGhost
  # SessionStore connects LittleGhost conversations to application
  # persistence. Subclass it to keep sessions in a database, remote service, or
  # other durable store.
  #
  #   class DatabaseSessionStore < LittleGhost::SessionStore
  #     def load(id, actor_id: nil)
  #       Conversation.find_by(external_id: id, actor_id:)&.snapshot
  #     end
  #
  #     def append(id, messages:, state:, metadata:, expected_count:, actor_id: nil)
  #       Conversation.append!(
  #         id, messages:, state:, metadata:, expected_count:, actor_id:
  #       )
  #     end
  #
  #     def replace(id, messages:, state:, metadata:, actor_id: nil)
  #       Conversation.replace!(id, messages:, state:, metadata:, actor_id:)
  #     end
  #   end
  #
  # A snapshot contains +:messages+, +:state+, and +:metadata+. State and
  # metadata cross this boundary as deeply string-keyed JSON mappings. Sessions
  # expose the same data through DataMap, which accepts String or Symbol keys.
  # Implementations provide #load, #append, and #replace; #append must check
  # +expected_count+ atomically so two writers cannot silently lose a turn.
  #
  # Actor identity always comes from the caller. A store must not infer it from
  # ambient process state.
  class SessionStore
    # Prepares the per-session synchronization used by #synchronize.
    def initialize
      @session_locks = {}
      @session_locks_mutex = Mutex.new
    end

    # Finds the snapshot for +id+, or returns nil when it does not exist.
    def load(_id, actor_id: nil)
      raise AbstractMethodError, "#{self.class} must implement #load"
    end

    # Atomically appends sanitized messages and stores canonical JSON state and
    # metadata.
    # Implementations raise ProtocolError if the persisted message count differs
    # from +expected_count+.
    def append(_id, messages:, state:, metadata:, expected_count:, actor_id: nil)
      raise AbstractMethodError, "#{self.class} must implement #append"
    end

    # Replaces the complete snapshot for +id+ atomically with canonical JSON
    # state and metadata.
    def replace(_id, messages:, state:, metadata:, actor_id: nil)
      raise AbstractMethodError, "#{self.class} must implement #replace"
    end

    # Stores may expose a clean conversational view without changing the stored
    # session transcript. The default implementation is a no-op.
    def project_conversation(_id, messages:, metadata:, actor_id: nil)
      nil
    end

    # Wraps a store operation with an optional telemetry parent operation.
    # Custom stores may override this while preserving the block's return value.
    def with_operation_context(_operation_id)
      yield
    end

    # Serializes work for one actor/session key within this store instance.
    def synchronize(id, actor_id: nil)
      key = [actor_id&.to_s, id.to_s].freeze
      entry = @session_locks_mutex.synchronize do
        current = (@session_locks[key] ||= [Mutex.new, 0])
        current[1] += 1
        current
      end
      entry.first.synchronize { yield }
    ensure
      if entry
        @session_locks_mutex.synchronize do
          entry[1] -= 1
          @session_locks.delete(key) if entry[1].zero?
        end
      end
    end

    protected

    def persistable_messages(messages)
      messages.filter_map do |value|
        message = Message.coerce(value)
        sanitized = message.without_reasoning
        next if sanitized.content.empty? && !message.content.empty?

        sanitized
      end.freeze
    end
  end
end
