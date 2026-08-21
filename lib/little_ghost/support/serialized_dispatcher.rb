# frozen_string_literal: true

module LittleGhost
  module Support
    class SerializedDispatcher # :nodoc:
      Entry = Struct.new(:value, :condition, :finished, :error)

      def initialize(&callback)
        raise ArgumentError, "callback is required" unless callback

        @callback = callback
        @mutex = Mutex.new
        @queue = []
        @draining = false
        @owner = nil
        @failure = nil
      end

      def call(value)
        entry = Entry.new(value, ConditionVariable.new, false, nil)
        identity = [Thread.current, Fiber.current]
        @mutex.synchronize do
          raise @failure if @failure

          @queue << entry
          if @draining
            return value if @owner == identity

            entry.condition.wait(@mutex) until entry.finished
            raise entry.error if entry.error

            return value
          end

          @draining = true
          @owner = identity
        end

        drain_queue
        raise entry.error if entry.error

        value
      end

      private

      def drain_queue
        loop do
          entry = @mutex.synchronize do
            value = @queue.shift
            unless value
              @draining = false
              @owner = nil
            end
            value
          end
          return unless entry

          @callback.call(entry.value)
          @mutex.synchronize do
            entry.finished = true
            entry.condition.broadcast
          end
        rescue => error
          @mutex.synchronize do
            @failure = error
            entry.error = error
            entry.finished = true
            entry.condition.broadcast
            @queue.each do |queued|
              queued.error = error
              queued.finished = true
              queued.condition.broadcast
            end
            @queue.clear
            @draining = false
            @owner = nil
          end
          return
        end
      end
    end
  end
end
