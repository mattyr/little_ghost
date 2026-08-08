# frozen_string_literal: true

module LittleGhost
  module ExecutionState
    STORAGE_KEY = :little_ghost_execution_state
    EMPTY_STATE = {}.freeze

    class << self
      def [](key)
        state[key]
      end

      def []=(key, value)
        replace(state.merge(key => value))
      end

      def delete(key)
        value = state[key]
        replace(state.except(key))
        value
      end

      def capture
        state
      end

      def with(values)
        previous = state
        replace(previous.merge(values))
        yield
      ensure
        replace(previous)
      end

      private

      def state
        Fiber[STORAGE_KEY] || EMPTY_STATE
      end

      def replace(values)
        Fiber[STORAGE_KEY] = values.empty? ? nil : values.freeze
      end
    end
  end
end
