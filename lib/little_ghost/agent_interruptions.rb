# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class AgentInterruptions
    Response = Data.define(:text, :tool_calls, :interruption_ids, :batch_key) do
      def initialize(text:, tool_calls:, interruption_ids: [], batch_key: nil)
        super(
          text: String(text),
          tool_calls: !!tool_calls,
          interruption_ids: Array(interruption_ids).map { |id| String(id).dup.freeze }.freeze,
          batch_key: batch_key.nil? ? nil : String(batch_key).dup.freeze
        )
      end

      def tool_calls? = tool_calls
    end

    Batch = Data.define(:tickets) do
      def interruption_ids = tickets.map(&:id)
      def batch_key = tickets.first&.batch_key
      def metadata = tickets.last&.metadata
    end

    class Ticket
      attr_reader :id, :message, :batch_key, :metadata

      def initialize(message, id:, batch_key:, metadata:)
        @id = id
        @message = message
        @batch_key = batch_key
        @metadata = metadata
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
          cancellation_token.raise_if_cancelled!
          raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline
          raise @error if @error

          @value
        end
      end
    end

    attr_reader :operation_id, :target_operation_id

    def initialize
      @mutex = Mutex.new
      @queue = []
      @tickets_by_id = {}
      @waiters = Hash.new(0)
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

    def enqueue(message, id: SecureRandom.uuid, batch_key: nil, metadata: {})
      id = String(id)
      raise ArgumentError, "interruption_id cannot be empty" if id.empty?

      batch_key = String(batch_key) unless batch_key.nil?
      metadata = Support.immutable(metadata.to_h)
      @mutex.synchronize do
        raise @closed_error if @closed_error

        existing = @tickets_by_id[id]
        if existing
          unless existing.message.to_h == message.to_h &&
              existing.batch_key == batch_key &&
              existing.metadata == metadata
            raise ArgumentError, "interruption_id has already been used with different input"
          end

          @waiters[existing] += 1
          return existing
        end

        ticket = Ticket.new(message, id: id.freeze, batch_key: batch_key&.freeze, metadata:)
        @tickets_by_id[id] = ticket
        @waiters[ticket] = 1
        @queue << ticket
        ticket
      end
    rescue TypeError, NoMethodError
      raise ArgumentError, "interruption_id, batch_key, and metadata are invalid"
    end

    def deliver
      @mutex.synchronize do
        return if @delivered || @queue.empty?

        batch_key = @queue.first.batch_key
        tickets = []
        tickets << @queue.shift
        if batch_key
          tickets << @queue.shift while @queue.first && @queue.first.batch_key == batch_key
        end
        @delivered = Batch.new(tickets: tickets.freeze)
      end
    end

    def resolve(batch, response)
      tickets = @mutex.synchronize do
        return unless batch && @delivered.equal?(batch)

        @delivered = nil
        batch.tickets
      end
      tickets.each { |ticket| ticket.resolve(response) }
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

    def release(ticket, withdraw: false)
      @mutex.synchronize do
        @waiters[ticket] -= 1
        return unless withdraw && @waiters[ticket] <= 0 && @queue.delete(ticket)

        @tickets_by_id.delete(ticket.id)
        @waiters.delete(ticket)
      end
    end

    def close(error)
      tickets = @mutex.synchronize do
        return if @closed_error

        @closed_error = error
        values = [*@delivered&.tickets, *@queue].compact
        @delivered = nil
        @queue.clear
        values
      end
      tickets.each { |ticket| ticket.reject(error) }
    end
  end
end
