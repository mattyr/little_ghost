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
    # Mutable DataMap state supplied to this invocation. A top-level Run starts
    # with restored Session state merged with current Invocation context; child
    # Assemblies may receive copied, mapped, or empty state. Application code must
    # synchronize mutations when parallel Tools share this map, or use exclusive
    # Tools. String and Symbol keys address the same value; persisted snapshots
    # use canonical String keys.
    attr_reader :state
    # Token used to cooperatively stop the current work.
    attr_reader :cancellation_token
    # Wall-clock deadline for the current work, when present.
    attr_reader :deadline
    # Framework metadata attached to this context.
    attr_reader :metadata
    # Active Agent operation identifier, after the context is bound.
    attr_reader :agent_operation_id
    # Durable subagent conversation identifier, when present.
    attr_reader :conversation_id

    # Creates a context with optional checkpoint and interjection state.
    def initialize(
      state: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      metadata: {},
      checkpoint: nil,
      conversation_id: nil,
      interjection_metadata: nil,
      interjection_ids: []
    )
      if conversation_id
        conversation_id = String(conversation_id)
        raise ArgumentError, "conversation_id cannot be empty" if conversation_id.empty?
        conversation_id = conversation_id.dup.freeze
      end
      @state = DataMap.new(state)
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
      @interjection_mutex = Mutex.new
      @interjection_metadata = interjection_metadata&.to_h
      @interjection_ids = Array(interjection_ids).map { |id| String(id).dup.freeze }.freeze
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

    def interjection_metadata # :nodoc:
      @interjection_mutex.synchronize { @interjection_metadata }
    end

    def interjection_ids # :nodoc:
      @interjection_mutex.synchronize { @interjection_ids }
    end

    def activate_interjection(metadata:, ids:) # :nodoc:
      value = metadata&.to_h
      values = Array(ids).map { |id| String(id).dup.freeze }.freeze
      @interjection_mutex.synchronize do
        @interjection_metadata = value
        @interjection_ids = values
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
