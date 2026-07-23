# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Run
    include Enumerable

    attr_reader :application, :invocation, :cancellation_token, :result, :operation_id,
      :outcome, :response, :error, :session, :usage

    def initialize(invocation:, application:, cancellation_token: Support::CancellationToken.new)
      @application = application
      @invocation = invocation
      @cancellation_token = cancellation_token
      @operation_id = SecureRandom.uuid
      @resources = []
      @closed = false
      @started = false
      @mutex = Mutex.new
      @event_mutex = Mutex.new
      @exclusive_tools_mutex = Mutex.new
      @subagent_started_at = {}
      @usage = Usage.new
    end

    def call
      each { |_event| }
      self
    end

    def each
      return enum_for(__method__) unless block_given?

      begin_execution!
      @emitter = ->(event) { yield_event(event) { |value| yield value } }
      execute { |event| yield event }
      self
    ensure
      @emitter = nil
    end

    def completed? = outcome == "completed"
    def failed? = outcome == "failed"
    def partial? = outcome == "partial"
    def cancelled? = outcome == "cancelled"

    def context(state: {}, metadata: {})
      RunContext.new(
        state:,
        cancellation_token:,
        deadline: invocation.deadline_at,
        instrumentation: application.instrumentation,
        metadata:
      )
    end

    def publish(type, **data)
      event = StreamEvent.build(type, **data)
      telemetry = @event_mutex.synchronize do
        value = event_telemetry(type, data)
        @emitter&.call(event)
        value
      end
      instrument(*telemetry) if telemetry
      event
    end

    def register(resource = nil, &closer)
      callback = closer || close_callback(resource)
      @mutex.synchronize do
        raise Error, "run is already closed" if @closed
        @resources << callback
      end
      resource
    end

    def synchronize_exclusive_tools(&block)
      @exclusive_tools_mutex.synchronize(&block)
    end

    def close
      callbacks = @mutex.synchronize do
        return if @closed
        @closed = true
        @resources.reverse
      end
      errors = []
      callbacks.each do |callback|
        callback.call
      rescue => error
        errors << error
      end
      error = errors.find { |caught| caught.is_a?(CleanupError) } || errors.first
      raise error if error
    end

    private

    def execute
      started_at = monotonic_time
      current_response = nil
      last_response = +""
      response_before_model_attempt = +""
      terminal = nil
      execution_cleanup_error = nil
      instrument(
        :run_start,
        trace_context: invocation[:parent_trace_context],
        diagnostic: {input: diagnostic_invocation_message}
      )
      emit(:run_start, run_id: invocation.run_id, thread_id: invocation.session_id) { |event| yield event }
      trace_context = application.instrumentation.trace_context(operation_id:) if application.instrumentation.respond_to?(:trace_context)
      emit(:trace_context, context: trace_context) { |event| yield event } unless trace_context.nil? || trace_context.empty?
      @session = application.open_session(self)
      agent = application.build_agent(run: self)
      register(agent)
      invoke = lambda do
        history = session ? session.history(fallback: invocation.history) : invocation.history
        context = session ? session.state.merge(invocation.context) : invocation.context.dup

        agent.stream(
          invocation.message,
          history:,
          context:,
          settings: invocation.settings,
          template_locals: application.template_locals(run: self, agent:),
          template_paths: Array(invocation[:template_paths]),
          cancellation_token:,
          deadline: invocation.deadline_at,
          parent_operation_id: operation_id,
          checkpoint: ->(messages:, state:) { session&.checkpoint(messages:, state:) }
        ).each do |event|
          case event.type
          when :model_start
            response_before_model_attempt = last_response.dup
          when :message_start
            current_response = +""
          when :text_delta
            current_response ||= +""
            current_response << event.data[:text].to_s
          when :message_stop
            completed_response = current_response.to_s.strip
            last_response = completed_response unless completed_response.empty?
            current_response = nil
          when :model_retry
            current_response = nil
            last_response = response_before_model_attempt.dup
          end
          if event.type == :invocation_stop
            @result = event.data[:result]
            @usage = result.usage
          elsif event.type == :invocation_error
            @usage = event.data.fetch(:usage, usage)
          end
          yield event
        end
        session&.checkpoint_result(result) if result
      end
      session ? session.synchronize(&invoke) : invoke.call
      @outcome = "completed"
      @response = result&.text.to_s
      terminal = [:run_stop, {outcome:, response:, result:}]
    rescue DeadlineExceededError => caught
      @error = caught
      @outcome = "partial"
      @response = current_response.to_s.strip
      @response = last_response if @response.empty?
      terminal = [:run_partial, {outcome:, response:, error: caught}]
    rescue CancelledError => caught
      @error = caught
      @outcome = "cancelled"
      @response = ""
      terminal = [:run_cancel, {outcome:, response:, error: caught}]
    rescue => caught
      execution_cleanup_error = caught if caught.is_a?(CleanupError)
      @error = caught
      @outcome = "failed"
      @response = ""
      cleanup_failed = caught.is_a?(CleanupError)
      terminal = [
        :run_error,
        {
          outcome:,
          error: caught,
          message: cleanup_failed ? cleanup_error_message(caught) : application.error_message(caught, self),
          cleanup_failed:
        }
      ]
    ensure
      resource_cleanup_error = nil
      begin
        close
      rescue => caught
        resource_cleanup_error = caught
        reported_error = execution_cleanup_error || caught
        @error = reported_error
        @outcome = "failed"
        @response = ""
        terminal = [
          :run_error,
          {outcome:, error: reported_error, message: cleanup_error_message(reported_error), cleanup_failed: true}
        ]
      end

      stop_error = execution_cleanup_error || resource_cleanup_error || error
      stop_attributes = {
        outcome: ((execution_cleanup_error || resource_cleanup_error) ? "failed" : outcome)&.to_sym,
        duration_ms: duration_ms(started_at),
        error_type: stop_error&.class&.name,
        diagnostic: {
          output: failed? ? last_response : response,
          exception: stop_error && diagnostic_exception(stop_error)
        }.compact,
        **usage_attributes(usage)
      }.compact
      terminal_delivery_error = begin
        emit(terminal.first, **terminal.last) { |event| yield event } if terminal
        nil
      rescue => caught
        caught
      end
      instrumentation_error = begin
        instrument(:run_stop, stop_attributes)
        nil
      rescue => caught
        caught
      end
      final_errors = [
        execution_cleanup_error,
        resource_cleanup_error,
        terminal_delivery_error,
        instrumentation_error
      ].compact
      final_error = final_errors.find { |caught| caught.is_a?(CleanupError) } || final_errors.first
      raise final_error if final_error
    end

    def emit(type, **data, &block)
      emit_event(StreamEvent.build(type, **data), &block)
    end

    def emit_event(event)
      yield event
    end

    def yield_event(event)
      yield event
    end

    def instrument(name, attributes = {})
      application.instrumentation.emit(name, **correlation_attributes, **attributes.compact)
    end

    def correlation_attributes
      {
        operation_id:,
        run_id: invocation.run_id,
        invocation_id: invocation.invocation_id,
        session_id: invocation.session_id,
        agent_id: application.respond_to?(:agent_class) ? application.agent_class.agent_id : nil
      }.merge(application.respond_to?(:instrumentation_attributes) ? application.instrumentation_attributes(run: self) : {})
        .compact
    end

    def subagent_telemetry(data)
      value = data.fetch(:event)
      event = value[:event] || value["event"]
      attributes = {
        subagent_id: value[:subagent_id] || value["subagent_id"],
        kind: value[:kind] || value["kind"],
        turn: value[:turn] || value["turn"],
        status: value[:status] || value["status"]
      }.compact
      key = [attributes[:subagent_id], attributes[:turn]]
      case event
      when "turn_started"
        subagent_operation_id = value[:operation_id] || value["operation_id"] || SecureRandom.uuid
        @subagent_started_at[key] = [monotonic_time, subagent_operation_id]
        [:subagent_start, attributes.merge(operation_id: subagent_operation_id, parent_operation_id: operation_id)]
      when "turn_finished", "turn_failed", "cancelled"
        started = @subagent_started_at.delete(key)
        supplied_operation_id = value[:operation_id] || value["operation_id"]
        return unless started || supplied_operation_id

        started_at, subagent_operation_id = started
        outcome = {"turn_finished" => :completed, "turn_failed" => :error, "cancelled" => :cancelled}.fetch(event)
        subagent_operation_id ||= supplied_operation_id
        [
          :subagent_stop,
          attributes.merge(
            operation_id: subagent_operation_id,
            parent_operation_id: operation_id,
            outcome:,
            error_type: (event == "turn_failed") ? "LittleGhost::SubagentError" : nil,
            duration_ms: started_at && duration_ms(started_at)
          ).compact
        ]
      end
    end

    def event_telemetry(type, data)
      case type.to_sym
      when :subagent
        subagent_telemetry(data)
      when :model_retry
        error = data[:error]
        error_class = error.class.name if error.is_a?(Exception)
        error_class ||= error if error.is_a?(String) && error.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        [:model_retry, data.slice(:attempt, :delay).merge(error_class:).compact]
      end
    end

    def usage_attributes(usage)
      usage.respond_to?(:to_h) ? usage.to_h : {}
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_ms(started_at)
      ((monotonic_time - started_at) * 1_000).round(3)
    end

    def begin_execution!
      @mutex.synchronize do
        raise Error, "run has already started" if @started
        @started = true
      end
    end

    def close_callback(resource)
      raise ArgumentError, "resource must respond to close or a block must be provided" unless resource&.respond_to?(:close)

      -> { resource.close }
    end

    def cleanup_error_message(error)
      application.error_message(error, self)
    rescue
      "The run could not cleanly stop all work."
    end

    def diagnostic_invocation_message
      message = invocation.message
      return message unless message.respond_to?(:text)
      return message.text unless message.text.empty?

      message.to_h
    end

    def diagnostic_exception(error)
      {
        type: error.class.name,
        message: error.message,
        stacktrace: Array(error.backtrace).join("\n")
      }
    end
  end
end
