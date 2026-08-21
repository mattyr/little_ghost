# frozen_string_literal: true

module LittleGhost
  module Support
    # CancellationToken lets related work stop cooperatively without killing its
    # calling thread or fiber. Child tokens make cancellation flow through a
    # run's tree of work.
    #
    # Cancellation is idempotent and flows only downward. Long-running
    # extensions should call #raise_if_cancelled! at bounded intervals.
    class CancellationToken
      # Optionally attaches this token to +parent+.
      def initialize(parent: nil)
        @cancelled = false
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @children = {}
        @parent = parent
        parent&.send(:attach, self)
      end

      # Creates a child cancelled automatically with this token.
      def child = self.class.new(parent: self)

      # Cancels this token and all currently attached children.
      def cancel
        parent, children = @mutex.synchronize do
          return self if @cancelled

          @cancelled = true
          @condition.broadcast
          parent = @parent
          @parent = nil
          children = @children.keys
          @children.clear
          [parent, children]
        end
        parent&.send(:detach, self)
        children.each(&:cancel)
        self
      end

      # Indicates whether cancellation has been requested.
      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      # Raises CancelledError when cancellation has been requested.
      def raise_if_cancelled!
        raise CancelledError, "The run was cancelled" if cancelled?
      end

      # Waits up to +timeout+ seconds for cancellation.
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

      private

      def attach(child)
        cancelled = @mutex.synchronize do
          if @cancelled
            true
          else
            @children[child] = true
            false
          end
        end
        child.cancel if cancelled
      end

      def detach(child)
        @mutex.synchronize { @children.delete(child) }
      end
    end
  end
end
