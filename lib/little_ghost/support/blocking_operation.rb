# frozen_string_literal: true

module LittleGhost
  module Support
    # Runs the small number of framework-owned hot-path operations that cannot
    # reliably cooperate with a Fiber Scheduler on a lazy, bounded thread pool.
    # Once submitted, a caller waits through completion rather than abandoning
    # or forcibly killing the operation.
    module BlockingOperation # :nodoc:
      DEFAULT_CAPACITY = 2
      Job = Data.define(:operation, :response)
      Pool = Struct.new(:capacity, :queue, :workers, :in_flight, :condition)
      MUTEX = Mutex.new
      private_constant :Job, :Pool, :MUTEX

      module_function

      def capacity
        MUTEX.synchronize do
          reset_after_fork
          @capacity ||= DEFAULT_CAPACITY
        end
      end

      def capacity=(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "blocking_pool_capacity must be a positive integer"
        end

        MUTEX.synchronize do
          reset_after_fork
          if @pool && @capacity != value
            raise ConfigurationError, "blocking_pool_capacity cannot change after the blocking pool starts"
          end

          @capacity = value
        end
      end

      def call(&operation)
        return operation.call unless Fiber.current_scheduler

        job = build_job(operation)
        submit(pool, job, wait: true)
        receive(job)
      end

      def try_call(&operation)
        return [true, operation.call] unless Fiber.current_scheduler

        job = build_job(operation)
        return [false, nil] unless submit(pool, job, wait: false)

        [true, receive(job)]
      end

      def build_job(operation)
        Job.new(operation:, response: Queue.new)
      end

      def pool
        MUTEX.synchronize do
          reset_after_fork
          @capacity ||= DEFAULT_CAPACITY
          @pool ||= Pool.new(@capacity, Queue.new, [], 0, ConditionVariable.new)
        end
      end

      def submit(pool, job, wait:)
        MUTEX.synchronize do
          while pool.in_flight >= pool.capacity
            return false unless wait

            pool.condition.wait(MUTEX)
          end

          pool.workers.select!(&:alive?)
          target = [pool.in_flight + 1, pool.capacity].min
          pool.workers << Thread.new(pool) { |worker_pool| work(worker_pool) } while pool.workers.length < target
          pool.in_flight += 1
          pool.queue.push(job)
        end
        true
      end

      def receive(job)
        outcome = nil
        interruption = nil
        until outcome
          begin
            outcome = job.response.pop
          rescue Exception => error # rubocop:disable Lint/RescueException
            interruption ||= error
          end
        end

        raise interruption if interruption

        status, value = outcome
        raise value if status == :error

        value
      end

      def work(pool)
        Thread.current.name = "little-ghost-blocking"
        Thread.current.report_on_exception = false
        loop do
          job = pool.queue.pop
          begin
            job.response.push([:ok, job.operation.call])
          rescue Exception => error # rubocop:disable Lint/RescueException
            job.response.push([:error, error])
          ensure
            MUTEX.synchronize do
              pool.in_flight -= 1
              pool.condition.broadcast
            end
          end
        end
      end

      def reset_after_fork
        return if @worker_pid == Process.pid

        @worker_pid = Process.pid
        @pool = nil
      end
    end
  end
end
