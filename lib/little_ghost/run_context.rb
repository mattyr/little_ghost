# frozen_string_literal: true

module LittleGhost
  # RunContext gives tools and workflows one place for shared state, cancellation,
  # deadlines, checkpoints, and accumulated usage. It travels with work inside a
  # run without becoming global process state.
  #
  # Tools and workflows use it to share JSON-like state, check
  # cancellation and deadlines, checkpoint messages, and accumulate usage.
  # Access to framework-managed fields is thread-safe.
  class RunContext
    # Shared state, cancellation, deadline, metadata, operation identity, and
    # durable conversation identity for the current work.
    attr_reader :state, :cancellation_token, :deadline, :metadata,
      :agent_operation_id, :conversation_id

    # Creates a context with optional checkpoint and interruption state.
    def initialize(
      state: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      metadata: {},
      checkpoint: nil,
      conversation_id: nil,
      interruption_metadata: nil,
      interruption_ids: []
    )
      if conversation_id
        conversation_id = String(conversation_id)
        raise ArgumentError, "conversation_id cannot be empty" if conversation_id.empty?
        conversation_id = conversation_id.dup.freeze
      end
      @state = state
      @cancellation_token = cancellation_token
      @deadline = deadline
      @metadata = metadata.freeze
      @checkpoint = checkpoint
      @conversation_id = conversation_id
      @usage = Usage.new
      @usage_mutex = Mutex.new
      @structured_result = nil
      @structured_result_mutex = Mutex.new
      @agent_operation_id = nil
      @agent_operation_id_mutex = Mutex.new
      @interruption_mutex = Mutex.new
      @interruption_metadata = interruption_metadata&.to_h
      @interruption_ids = Array(interruption_ids).map { |id| String(id).dup.freeze }.freeze
    end

    # Raises LittleGhost::CancelledError or LittleGhost::DeadlineExceededError
    # when execution should stop.
    def check!
      cancellation_token.raise_if_cancelled!
      raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline
    end

    # Sends +messages+ and current state to the configured checkpoint callback.
    # With no checkpoint callback, this method does nothing and returns +nil+.
    def checkpoint(messages)
      return unless @checkpoint

      if agent_operation_id
        @checkpoint.call(messages:, state:, parent_operation_id: agent_operation_id)
      else
        @checkpoint.call(messages:, state:)
      end
    end

    # Adds +value+ to accumulated model usage.
    def record_usage(value)
      @usage_mutex.synchronize { @usage += value }
    end

    # Takes a snapshot of accumulated usage.
    def usage
      @usage_mutex.synchronize { @usage }
    end

    # Calculates seconds remaining before the deadline.
    #
    # When +maximum+ is provided, the result is capped at that value. With no
    # deadline, returns +maximum+.
    def remaining_time(maximum = nil)
      check!
      return maximum unless deadline

      remaining = deadline - Time.now
      maximum ? [remaining, maximum].min : remaining
    end

    # Stores a validated LittleGhost::StructuredResult and returns it.
    def submit_structured_result(result)
      @structured_result_mutex.synchronize { @structured_result = result }
      result
    end

    # Finds the latest validated structured result, if any.
    def structured_result
      @structured_result_mutex.synchronize { @structured_result }
    end

    def interruption_metadata # :nodoc:
      @interruption_mutex.synchronize { @interruption_metadata }
    end

    def interruption_ids # :nodoc:
      @interruption_mutex.synchronize { @interruption_ids }
    end

    def activate_interruption(metadata:, ids:) # :nodoc:
      value = metadata&.to_h
      values = Array(ids).map { |id| String(id).dup.freeze }.freeze
      @interruption_mutex.synchronize do
        @interruption_metadata = value
        @interruption_ids = values
      end
    end

    def bind_agent_operation_id(operation_id) # :nodoc:
      @agent_operation_id_mutex.synchronize do
        if @agent_operation_id && @agent_operation_id != operation_id
          raise Error, "run context is already bound to an agent operation"
        end

        @agent_operation_id ||= operation_id
      end
    end
  end
end
