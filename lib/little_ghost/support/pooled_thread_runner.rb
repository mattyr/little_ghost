# frozen_string_literal: true

module LittleGhost
  module Support
    # PooledThreadRunner starts Tasks on a fixed set of reusable threads. It is
    # used for calls that would otherwise pause every fiber on the caller's
    # thread.
    class PooledThreadRunner # :nodoc:
      DEFAULT_CAPACITY = 2
      CURRENT_RUNNER_KEY = Object.new.freeze # :nodoc:
      private_constant :CURRENT_RUNNER_KEY

      attr_reader :capacity

      def initialize(capacity: DEFAULT_CAPACITY)
        validate_capacity!(capacity)
        @capacity = capacity
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        reset_pool
      end

      def capacity=(value)
        validate_capacity!(value)
        @mutex.synchronize do
          reset_after_fork
          if @started && @capacity != value
            raise ConfigurationError, "blocking_pool_capacity cannot change after the blocking pool starts"
          end

          @capacity = value
        end
      end

      def spawn(&work)
        raise ArgumentError, "a task block is required" unless work

        task = build_pool_task(&work).start
        return task.tap(&:call) if current? || !current_scheduler

        submit(task, wait: true)
        task
      end

      def try_spawn(&work)
        raise ArgumentError, "a task block is required" unless work

        task = build_pool_task(&work).start
        return task.tap(&:call) if current? || !current_scheduler

        submit(task, wait: false) ? task : nil
      end

      private

      def build_pool_task(&work)
        Task.new(execution_state: ExecutionState.capture, capture_interruptions: true) do
          ExecutionState.with(CURRENT_RUNNER_KEY => self, &work)
        end
      end

      def current?
        ExecutionState[CURRENT_RUNNER_KEY].equal?(self)
      end

      def current_scheduler
        Fiber.current_scheduler
      end

      def submit(task, wait:)
        @mutex.synchronize do
          reset_after_fork
          while @in_flight >= @capacity
            return false unless wait

            @condition.wait(@mutex)
          end

          @workers.select!(&:alive?)
          target = [@in_flight + 1, @capacity].min
          while @workers.length < target
            @workers << Thread.new { work }
          end
          @started = true
          @in_flight += 1
          @queue.push(task)
        end
        true
      end

      def work
        Thread.current.name = "little-ghost-blocking"
        Thread.current.report_on_exception = false
        loop do
          task = @queue.pop
          begin
            task.call
          ensure
            @mutex.synchronize do
              @in_flight -= 1
              @condition.broadcast
            end
          end
        end
      end

      def reset_after_fork
        reset_pool unless @worker_pid == Process.pid
      end

      def reset_pool
        @worker_pid = Process.pid
        @queue = Queue.new
        @workers = []
        @in_flight = 0
        @started = false
      end

      def validate_capacity!(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "blocking_pool_capacity must be a positive integer"
        end
      end
    end
  end
end
