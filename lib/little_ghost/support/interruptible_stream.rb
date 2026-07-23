# frozen_string_literal: true

module LittleGhost
  module Support
    class InterruptibleStream
      include Enumerable

      class CleanupError < LittleGhost::CleanupError; end

      POLL_INTERVAL = 0.05
      SHUTDOWN_TIMEOUT = 0.1
      BUFFER_SIZE = 16

      def initialize(cancellation_token:, deadline: nil, buffer_size: BUFFER_SIZE, &producer)
        raise ArgumentError, "producer is required" unless producer

        @cancellation_token = cancellation_token
        @deadline = deadline
        @buffer_size = Integer(buffer_size)
        @producer = producer
        raise ArgumentError, "buffer_size must be positive" unless @buffer_size.positive?
      end

      def each
        return enum_for(__method__) unless block_given?

        queue = SizedQueue.new(@buffer_size)
        worker = Thread.new do
          @producer.call(->(value) { queue << [:value, value] })
        rescue => error
          queue << [:error, error]
        end
        worker.report_on_exception = false

        loop do
          check!
          break if !worker.alive? && queue.empty?

          item = next_item(queue)
          unless item
            break if !worker.alive? && queue.empty?
            next
          end

          type, value = item
          check!
          case type
          when :value then yield value
          when :error then raise value
          end
        end
        self
      ensure
        if worker
          worker.kill if worker.alive?
          worker.join(SHUTDOWN_TIMEOUT)
          if worker.alive?
            raise CleanupError,
              "stream producer did not stop within #{SHUTDOWN_TIMEOUT} seconds"
          end
        end
      end

      private

      def next_item(queue)
        queue.pop(timeout: wait_timeout)
      rescue ThreadError
        nil
      end

      def wait_timeout
        return POLL_INTERVAL unless @deadline

        (@deadline - Time.now).clamp(0, POLL_INTERVAL)
      end

      def check!
        @cancellation_token.raise_if_cancelled!
        raise DeadlineExceededError, "The run deadline was reached" if @deadline && Time.now >= @deadline
      end
    end
  end
end
