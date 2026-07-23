# frozen_string_literal: true

module LittleGhost
  class RunContext
    attr_reader :state, :cancellation_token, :deadline, :instrumentation, :metadata

    def initialize(
      state: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      instrumentation: nil,
      metadata: {},
      checkpoint: nil
    )
      @state = state
      @cancellation_token = cancellation_token
      @deadline = deadline
      @instrumentation = instrumentation || Support::Instrumentation.new
      @metadata = metadata.freeze
      @checkpoint = checkpoint
      @usage = Usage.new
      @usage_mutex = Mutex.new
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
  end
end
