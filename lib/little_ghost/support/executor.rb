# frozen_string_literal: true

module LittleGhost
  module Support
    # Executor runs independent work concurrently while preserving input order in
    # the final results. It gives framework extensions bounded parallelism without
    # losing cancellation or request-scoped state.
    #
    # ExecutionState is copied to workers. +on_result+ runs on the calling
    # execution context in completion order. After all workers join, the first
    # cleanup error, or otherwise the first input-order error, is raised.
    class Executor
      # Sets the maximum number of worker tasks and their scheduling policy.
      def initialize(max_concurrency: 8, task_runner: TaskRunner.new)
        raise ArgumentError, "max_concurrency must be at least 1" if max_concurrency < 1
        raise ArgumentError, "task_runner must be a LittleGhost::Support::TaskRunner" unless task_runner.is_a?(TaskRunner)

        @max_concurrency = max_concurrency
        @task_runner = task_runner
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
            workers << @task_runner.spawn do
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
    end
  end
end
