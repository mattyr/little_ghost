# frozen_string_literal: true

module LittleGhost
  module Support
    # Runs the small number of framework-owned hot-path operations that cannot
    # cooperate with a Fiber Scheduler on lazily created, bounded thread pools.
    # Once submitted, a caller waits through completion rather than abandoning
    # or forcibly killing the operation.
    module BlockingOperation # :nodoc:
      Job = Data.define(:operation, :execution_state, :response)
      Pool = Struct.new(:name, :limit, :queue, :workers, :in_flight, :condition)
      POOL_LIMITS = {default: 2, filesystem: 4}.freeze
      MUTEX = Mutex.new
      private_constant :Job, :Pool, :POOL_LIMITS, :MUTEX

      module_function

      def call(lane: :default, on_interruption: nil, &operation)
        return operation.call unless Fiber.current_scheduler

        job = build_job(operation)
        submit(pool(lane), job, wait: true)
        receive(job, on_interruption:)
      end

      def try_call(lane:, on_interruption: nil, &operation)
        return [true, operation.call] unless Fiber.current_scheduler

        job = build_job(operation)
        return [false, nil] unless submit(pool(lane), job, wait: false)

        [true, receive(job, on_interruption:)]
      end

      def build_job(operation)
        Job.new(operation:, execution_state: ExecutionState.capture, response: Queue.new)
      end

      def pool(lane)
        limit = POOL_LIMITS.fetch(lane) { raise ArgumentError, "unknown blocking-operation lane: #{lane.inspect}" }
        MUTEX.synchronize do
          if @worker_pid != Process.pid
            @worker_pid = Process.pid
            @pools = {}
          end
          @pools[lane] ||= Pool.new(lane, limit, SizedQueue.new(limit), [], 0, ConditionVariable.new)
        end
      end

      def submit(pool, job, wait:)
        MUTEX.synchronize do
          while pool.in_flight >= pool.limit
            return false unless wait

            pool.condition.wait(MUTEX)
          end
          pool.in_flight += 1
          pool.queue.push(job)
          pool.workers.select!(&:alive?)
          target = [pool.in_flight, pool.limit].min
          begin
            pool.workers << Thread.new(pool) { |worker_pool| work(worker_pool) } while pool.workers.length < target
          rescue ThreadError
            if pool.workers.empty?
              queued_job = pool.queue.pop(true)
              raise "blocking-operation admission lost its queued job" unless queued_job.equal?(job)

              pool.in_flight -= 1
              pool.condition.broadcast
              raise
            end
          end
        end
        true
      end

      def receive(job, on_interruption:)
        outcome = nil
        interruption = nil
        until outcome
          begin
            outcome = job.response.pop
          rescue Exception => error # rubocop:disable Lint/RescueException
            interruption ||= error
          end
        end

        status, value = outcome
        if interruption
          on_interruption&.call(value) if status == :ok
          raise interruption
        end
        raise value if status == :error

        value
      end

      def work(pool)
        Thread.current.name = "little-ghost-blocking-#{pool.name}"
        Thread.current.report_on_exception = false
        loop do
          job = pool.queue.pop
          begin
            value = ExecutionState.with(job.execution_state, &job.operation)
            job.response.push([:ok, value])
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
    end
  end
end
