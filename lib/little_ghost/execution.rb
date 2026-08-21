# frozen_string_literal: true

module LittleGhost
  # Runs one dormant Run in the background while the caller remains free to
  # serve health checks, deliver interjections, or coordinate shutdown.
  #
  #   execution = agent.start_execution(message: "Investigate transfer 481") do |event|
  #     event_buffer << event
  #   end
  #
  #   execution.interject(message: "Include the latest ledger entry")
  #   execution.wait(deadline: Time.now + 30)
  #   execution.run.completed? # => true
  #
  # The Runtime selects a scheduled fiber or worker thread for the execution.
  # LittleGhost copies the caller's ExecutionState, but not other application
  # fiber-local or thread-local values. The Run continues to own its workspace,
  # sandbox, session, entrypoint, and registered resources. +close+ requests
  # cooperative cancellation and waits for the execution and any in-flight
  # interjection calls.
  class Execution
    # The supervised Run.
    attr_reader :run

    class << self
      # Starts +run+ immediately and returns its supervising Execution. If the
      # work cannot start, this method closes +run+ before raising.
      #
      # The optional block receives each StreamEvent from the fiber or thread
      # running the Execution. It must not depend on a particular thread and
      # should not pause the scheduler or retain sensitive event content longer
      # than the application requires.
      def start(run, &event_consumer)
        new(run, event_consumer:).send(:start)
      end
    end

    def initialize(run, event_consumer: nil) # :nodoc:
      raise ArgumentError, "run must be a LittleGhost::Run" unless run.is_a?(Run)
      unless event_consumer.nil? || event_consumer.respond_to?(:call)
        raise ArgumentError, "event consumer must be callable"
      end

      @run = run
      @event_consumer = event_consumer
      @state = :pending
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @active_interjections = 0
      @closing = false
      @task_runner = run.runtime.task_runner
    end

    # Returns +:pending+, +:running+, or +:finished+.
    def state
      @mutex.synchronize { @state }
    end

    # Returns an event-delivery or cleanup exception raised by the Execution.
    def error
      @mutex.synchronize { @worker }&.error
    end

    # Indicates that the Execution or an interjection call is still active.
    def active?
      @mutex.synchronize { @state != :finished || @active_interjections.positive? }
    end

    # Indicates that the Execution and all interjection calls have finished.
    def finished?
      !active?
    end

    # Prepares and delivers one interjection to the active run.
    #
    # +payload+ may be a message or a Hash containing +message+ and the options
    # accepted by Run#interject. Runtime hooks receive the Hash before
    # delivery, allowing them to materialize trusted application attachments.
    # Calls may overlap, but +close+ prevents new calls and waits for calls that
    # have already begun.
    def interject(payload = nil, **options)
      if payload.nil? && options.key?(:message)
        payload = options.delete(:message)
      end
      interjection_started = false
      begin_interjection!
      interjection_started = true
      run.interject_with do
        prepared = run.prepare_interjection(interjection_payload(payload, options))
        interjection_arguments(prepared, options)
      end
    ensure
      finish_interjection! if interjection_started
    end

    # Requests cooperative cancellation and returns +self+.
    def cancel
      run.cancellation_token.cancel
      self
    end

    # Waits for the Execution and in-flight interjections, then returns the Run.
    #
    # +deadline+ is an absolute Time. Reaching it raises DeadlineExceededError
    # without cancelling the run. An event-delivery or cleanup failure raised by
    # the Execution is re-raised after all supervised work finishes.
    def wait(deadline: nil)
      worker = wait_until_finished(deadline:)
      worker.wait
      caught = worker.error
      raise caught if caught

      run
    end

    # Prevents new interjections, requests cancellation, and waits for shutdown.
    # The operation is idempotent. +deadline+ has the same meaning as in #wait.
    def close(deadline: nil)
      @mutex.synchronize { @closing = true }
      cancel
      wait(deadline:)
    end

    protected

    def start # :nodoc:
      @mutex.synchronize do
        raise Error, "execution has already started" unless @state == :pending

        @state = :running
      end
      worker = @task_runner.spawn { execute }
      @mutex.synchronize { @worker = worker }
      self
    rescue
      @mutex.synchronize do
        @state = :finished
        @condition.broadcast
      end
      run.close
      raise
    end

    private

    def execute
      run.each { |event| @event_consumer&.call(event) }
    ensure
      @mutex.synchronize do
        @state = :finished
        @condition.broadcast
      end
    end

    def begin_interjection!
      @mutex.synchronize do
        raise AgentInterjectionError, "Execution is closing" if @closing
        raise AgentInterjectionError, "Execution has already finished" if @state == :finished

        @active_interjections += 1
      end
    end

    def finish_interjection!
      @mutex.synchronize do
        @active_interjections -= 1 if @active_interjections.positive?
        @condition.broadcast
      end
    end

    def interjection_payload(payload, options)
      values = payload.is_a?(Hash) ? payload.dup : {message: payload}
      options.each { |key, value| values[key] = value }
      values
    end

    def interjection_arguments(prepared, fallback)
      unless prepared.is_a?(Hash)
        return [prepared, fallback.slice(:interjection_id, :batch_key, :metadata, :cancellation_token, :deadline)]
      end

      values = prepared.transform_keys(&:to_sym)
      message = values.delete(:message) { raise ArgumentError, "prepared interjection must include a message" }
      allowed = values.slice(:interjection_id, :batch_key, :metadata, :cancellation_token, :deadline)
      [message, fallback.slice(:interjection_id, :batch_key, :metadata, :cancellation_token, :deadline).merge(allowed)]
    end

    def wait_until_finished(deadline:)
      monotonic_deadline = if deadline
        monotonic_time + [deadline - Time.now, 0].max
      end
      @mutex.synchronize do
        until @state == :finished && @active_interjections.zero?
          if monotonic_deadline
            remaining = monotonic_deadline - monotonic_time
            raise DeadlineExceededError, "Execution did not finish before the wait deadline" unless remaining.positive?

            @condition.wait(@mutex, remaining)
          else
            @condition.wait(@mutex)
          end
        end
        @worker
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
