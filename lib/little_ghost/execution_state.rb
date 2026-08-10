# frozen_string_literal: true

module LittleGhost
  # ExecutionState carries request-scoped values across fibers and the worker
  # threads LittleGhost creates. It keeps event and instrumentation context from
  # leaking between concurrent runs.
  #
  # Framework extensions may use #capture and #with to preserve event and
  # instrumentation context. Captured hashes are immutable; values within them
  # are not deep-copied.
  module ExecutionState
    STORAGE_KEY = :little_ghost_execution_state # :nodoc:
    EMPTY_STATE = {}.freeze # :nodoc:

    class << self
      # Reads +key+ from the current execution state.
      def [](key)
        state[key]
      end

      # Replaces +key+ in the current fiber-local state.
      def []=(key, value)
        replace(state.merge(key => value))
      end

      # Deletes +key+ and returns its previous value.
      def delete(key)
        value = state[key]
        replace(state.except(key))
        value
      end

      # Captures the current immutable state hash for propagation.
      def capture
        state
      end

      # Merges +values+ while the block runs, then restores prior state.
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
