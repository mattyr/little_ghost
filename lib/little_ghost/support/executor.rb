# frozen_string_literal: true

module LittleGhost
  module Support
    # Executor runs independent work concurrently while preserving input order in
    # the final results. It gives framework extensions bounded parallelism without
    # losing cancellation or request-scoped state.
    #
    # ExecutionState is copied to workers. +on_result+ runs on the caller in
    # completion order. After all workers join, the first
    # cleanup error, or otherwise the first input-order error, is raised.
    class Executor # :nodoc:
      # Sets the maximum number of batch workers and their execution policy.
      def initialize(max_concurrency: 8, runner: TaskRunner.new, wait_through_interruptions: false)
        raise ArgumentError, "max_concurrency must be at least 1" if max_concurrency < 1

        @max_concurrency = max_concurrency
        @runner = runner
        @wait_through_interruptions = wait_through_interruptions
      end

      attr_reader :runner # :nodoc:

      # Submits one unit of work and returns its Task.
      def submit(&work)
        @runner.spawn(&work)
      end

      # Runs one unit of work and returns its result.
      def call(&work)
        resolve(submit(&work))
      end

      # Runs one unit of work only when runner capacity is immediately
      # available. Returns an accepted flag and the result.
      def try_call(&work)
        task = @runner.try_spawn(&work)
        return [false, nil] unless task

        [true, resolve(task)]
      end

      # Maps +values+ with at most the configured number of workers.
      def map(values, cancellation_token: CancellationToken.new, on_result: nil, &block)
        unless on_result.nil? || on_result.respond_to?(:call)
          raise ArgumentError, "on_result must be callable"
        end

        items = values.to_a
        return [] if items.empty?

        queue = Queue.new
        completions = Queue.new
        items.each_index { |index| queue << index }
        results = Array.new(items.length)
        errors = Array.new(items.length)
        error_mutex = Mutex.new
        first_worker_error = nil
        worker_count = [@max_concurrency, items.length].min
        workers = []
        begin
          worker_count.times do
            workers << submit do
              loop do
                index = begin
                  queue.pop(true)
                rescue ThreadError
                  break
                end

                begin
                  cancellation_token.raise_if_cancelled!
                  results[index] = block.call(items[index])
                rescue => error
                  errors[index] = error
                  error_mutex.synchronize { first_worker_error ||= error }
                  cancellation_token.cancel
                ensure
                  completions << index
                end
              end
            ensure
              completions << :worker_finished
            end
          end
        rescue
          cancellation_token.cancel
          workers.each(&:wait)
          raise
        end
        callback_error = nil
        begin
          completed_items = 0
          finished_workers = 0
          until completed_items == items.length || finished_workers == workers.length
            completion = completions.pop
            if completion == :worker_finished
              finished_workers += 1
              next
            end

            completed_items += 1
            begin
              on_result.call(completion, results[completion]) if on_result && !errors[completion]
            rescue => error
              callback_error = error
              cancellation_token.cancel
              break
            end
          end
        ensure
          workers.each(&:wait)
        end

        raise callback_error if callback_error
        task_error = workers.filter_map(&:error).first
        raise task_error if task_error

        first_error = errors.compact.find { |error| error.is_a?(CleanupError) } || first_worker_error
        raise first_error if first_error

        results
      end

      private

      def resolve(task)
        interruption = nil
        loop do
          task.wait
          break
        rescue Exception => error # rubocop:disable Lint/RescueException
          raise unless @wait_through_interruptions

          interruption ||= error
          break unless task.alive?
        end
        raise interruption if interruption
        raise task.error if task.error

        task.result
      end

      # The process-wide Executor for work moved off a scheduler thread.
      BLOCKING = new(
        runner: PooledThreadRunner.new,
        wait_through_interruptions: true
      ) # :nodoc:
      private_constant :BLOCKING

      class << self
        def blocking = BLOCKING # :nodoc:
      end
    end
  end
end
