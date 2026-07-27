# frozen_string_literal: true

module LittleGhost
  class RunContext
    attr_reader :state, :cancellation_token, :deadline, :instrumentation, :metadata,
      :agent_operation_id, :conversation_id

    def initialize(
      state: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      instrumentation: nil,
      metadata: {},
      checkpoint: nil,
      conversation_id: nil
    )
      if conversation_id
        conversation_id = String(conversation_id)
        raise ArgumentError, "conversation_id cannot be empty" if conversation_id.empty?
        conversation_id = conversation_id.dup.freeze
      end
      @state = state
      @cancellation_token = cancellation_token
      @deadline = deadline
      @instrumentation = instrumentation || Support::Instrumentation.new
      @metadata = metadata.freeze
      @checkpoint = checkpoint
      @conversation_id = conversation_id
      @usage = Usage.new
      @usage_mutex = Mutex.new
      @structured_result = nil
      @structured_result_mutex = Mutex.new
      @agent_operation_id = nil
      @agent_operation_id_mutex = Mutex.new
    end

    def check!
      cancellation_token.raise_if_cancelled!
      raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline
    end

    def checkpoint(messages)
      @checkpoint&.call(messages:, state:)
    end

    def record_usage(value)
      @usage_mutex.synchronize { @usage += value }
    end

    def usage
      @usage_mutex.synchronize { @usage }
    end

    def remaining_time(maximum = nil)
      check!
      return maximum unless deadline

      remaining = deadline - Time.now
      maximum ? [remaining, maximum].min : remaining
    end

    def submit_structured_result(result)
      @structured_result_mutex.synchronize { @structured_result = result }
      result
    end

    def structured_result
      @structured_result_mutex.synchronize { @structured_result }
    end

    def bind_agent_operation_id(operation_id)
      @agent_operation_id_mutex.synchronize do
        if @agent_operation_id && @agent_operation_id != operation_id
          raise Error, "run context is already bound to an agent operation"
        end

        @agent_operation_id ||= operation_id
      end
    end
  end
end
