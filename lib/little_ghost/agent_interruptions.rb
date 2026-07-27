# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class AgentInterruptions
    class Ticket
      attr_reader :id, :message

      def initialize(message)
        @id = SecureRandom.uuid
        @message = message
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @resolved = false
      end

      def resolve(value)
        @mutex.synchronize do
          return if @resolved

          @value = value
          @resolved = true
          @condition.broadcast
        end
      end

      def reject(error)
        @mutex.synchronize do
          return if @resolved

          @error = error
          @resolved = true
          @condition.broadcast
        end
      end

      def value(cancellation_token:, deadline:)
        @mutex.synchronize do
          until @resolved
            cancellation_token.raise_if_cancelled!
            raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline

            timeout = deadline ? [deadline - Time.now, 0.05].min : 0.05
            @condition.wait(@mutex, [timeout, 0].max)
          end
          raise @error if @error

          @value
        end
      end
    end

    attr_reader :operation_id, :target_operation_id

    def initialize
      @mutex = Mutex.new
      @queue = []
      @delivered = nil
      @closed_error = nil
      @operation_id = nil
      @target_operation_id = nil
    end

    def bind(operation_id, target_operation_id:)
      @mutex.synchronize do
        @operation_id = operation_id
        @target_operation_id = target_operation_id || operation_id
      end
    end

    def enqueue(message)
      ticket = Ticket.new(message)
      @mutex.synchronize do
        raise @closed_error if @closed_error

        @queue << ticket
      end
      ticket
    end

    def deliver
      @mutex.synchronize do
        return if @delivered

        @delivered = @queue.shift
      end
    end

    def resolve(ticket, text)
      @mutex.synchronize do
        return unless ticket && @delivered.equal?(ticket)

        @delivered = nil
      end
      ticket.resolve(text)
    end

    def pending?
      @mutex.synchronize { !@queue.empty? }
    end

    def finish
      @mutex.synchronize do
        return true if @closed_error
        return false if @delivered || !@queue.empty?

        @closed_error = AgentInterruptError.new("Agent is not currently running")
        true
      end
    end

    def withdraw(ticket)
      @mutex.synchronize { @queue.delete(ticket) }
    end

    def close(error)
      tickets = @mutex.synchronize do
        return if @closed_error

        @closed_error = error
        values = [@delivered, *@queue].compact
        @delivered = nil
        @queue.clear
        values
      end
      tickets.each { |ticket| ticket.reject(error) }
    end
  end
end
