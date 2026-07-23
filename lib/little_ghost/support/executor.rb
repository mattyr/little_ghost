# frozen_string_literal: true

module LittleGhost
  module Support
    class Executor
      def initialize(max_concurrency: 8)
        raise ArgumentError, "max_concurrency must be at least 1" if max_concurrency < 1

        @max_concurrency = max_concurrency
      end

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
        worker_count = [@max_concurrency, items.length].min

        workers = worker_count.times.map do
          Thread.new do
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
              ensure
                completions << index
              end
            end
          end
        end
        begin
          items.length.times do
            index = completions.pop
            on_result.call(index, results[index]) if on_result && !errors[index]
          end
        ensure
          workers.each(&:join)
        end

        first_error = errors.compact.find { |error| error.is_a?(CleanupError) } || errors.compact.first
        raise first_error if first_error

        results
      end
    end
  end
end
