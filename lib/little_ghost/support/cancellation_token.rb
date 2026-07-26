# frozen_string_literal: true

module LittleGhost
  module Support
    class CancellationToken
      def initialize(parent: nil)
        @cancelled = false
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @children = {}
        @parent = parent
        parent&.send(:attach, self)
      end

      def child = self.class.new(parent: self)

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
