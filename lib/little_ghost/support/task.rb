# frozen_string_literal: true

module LittleGhost
  module Support
    # Task represents one unit of framework-owned concurrent work. It provides
    # the same completion contract whether TaskRunner selected a thread or a
    # scheduler-owned fiber.
    class Task # :nodoc:
      CURRENT_KEY = :little_ghost_support_task # :nodoc:

      class << self
        # Returns the Task currently running in this execution context, if any.
        def current
          ExecutionState[CURRENT_KEY]
        end
      end

      def initialize(execution_state:, capture_interruptions: false, &work) # :nodoc:
        @execution_state = execution_state
        @capture_interruptions = capture_interruptions
        @work = work
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @finished = false
        @result = nil
        @error = nil
        @terminable = false
        @joinable = false
      end

      # Waits for completion and returns this Task.
      #
      # +deadline+ is an absolute Time. Reaching it raises
      # DeadlineExceededError without stopping the task.
      def wait(deadline: nil)
        raise Error, "a task cannot wait for itself" if current?

        monotonic_deadline = if deadline
          monotonic_time + [deadline - Time.now, 0].max
        end
        worker, joinable = @mutex.synchronize do
          until @finished
            if monotonic_deadline
              remaining = monotonic_deadline - monotonic_time
              raise DeadlineExceededError, "Task did not finish before the wait deadline" unless remaining.positive?

              @condition.wait(@mutex, remaining)
            else
              @condition.wait(@mutex)
            end
          end
          [@worker, @joinable]
        end
        worker.join if joinable
        self
      end

      # Returns the task result after completion.
      def result
        @mutex.synchronize { @result }
      end

      # Returns the worker failure after completion, or nil.
      def error
        @mutex.synchronize { @error }
      end

      # Indicates that the task has not finished.
      def alive?
        @mutex.synchronize { !@finished }
      end

      # Indicates that the caller is this task's worker execution context.
      def current?
        equal?(self.class.current)
      end

      # Requests forceful termination of a thread-backed task. Fiber tasks are
      # cooperatively cancelled by their owning operation, so this method
      # returns false for them. The owner remains responsible for a bounded
      # wait after termination.
      def terminate
        return false unless @terminable
        return false if current?

        worker = @mutex.synchronize { @worker unless @finished }
        return false unless worker

        worker.kill
        true
      end

      def start(worker = nil, terminable: false, joinable: false) # :nodoc:
        @mutex.synchronize do
          @worker = worker
          @terminable = terminable
          @joinable = joinable
        end
        self
      end

      def call # :nodoc:
        ExecutionState.with(@execution_state) do
          result = ExecutionState.with(CURRENT_KEY => self) { @work.call }
          @mutex.synchronize { @result = result }
        end
      rescue => caught
        @mutex.synchronize { @error = caught }
      rescue Exception => caught # rubocop:disable Lint/RescueException
        raise unless @capture_interruptions

        @mutex.synchronize { @error = caught }
      ensure
        @mutex.synchronize do
          @finished = true
          @condition.broadcast
        end
      end

      private

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
