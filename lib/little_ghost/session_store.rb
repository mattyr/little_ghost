# frozen_string_literal: true

module LittleGhost
  class SessionStore
    def initialize
      @session_locks = {}
      @session_locks_mutex = Mutex.new
    end

    def load(_id, actor_id: nil)
      raise NotImplementedError
    end

    def append(_id, messages:, state:, metadata:, expected_count:, actor_id: nil)
      raise NotImplementedError
    end

    def replace(_id, messages:, state:, metadata:, actor_id: nil)
      raise NotImplementedError
    end

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
