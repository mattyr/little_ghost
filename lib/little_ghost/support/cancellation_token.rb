# frozen_string_literal: true

module LittleGhost
  module Support
    class CancellationToken
      def initialize
        @cancelled = false
        @mutex = Mutex.new
        @condition = ConditionVariable.new
      end

      def cancel
        @mutex.synchronize do
          @cancelled = true
          @condition.broadcast
        end
        self
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      def raise_if_cancelled!
        raise CancelledError, "The run was cancelled" if cancelled?
      end

      def wait(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(timeout)
        @mutex.synchronize do
          until @cancelled
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break unless remaining.positive?

            @condition.wait(@mutex, remaining)
          end
          @cancelled
        end
      end
    end
  end
end
