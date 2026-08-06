# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Run
    include Enumerable

    attr_reader :runtime, :agent_class, :entrypoint_class, :invocation, :cancellation_token, :result, :operation_id,
      :outcome, :response, :error, :session, :usage

    def initialize(invocation:, agent_class:, runtime:, entrypoint_class: agent_class,
      cancellation_token: Support::CancellationToken.new)
      @runtime = runtime
      @agent_class = agent_class
      @entrypoint_class = entrypoint_class
      @invocation = invocation
      @cancellation_token = cancellation_token
      @operation_id = SecureRandom.uuid
      @resources = []
      @closed = false
      @started = false
      @mutex = Mutex.new
      @event_mutex = Mutex.new
      @exclusive_tools_mutex = Mutex.new
      @interruption_mutex = Mutex.new
      @interruption_state = :not_started
      @entrypoint = nil
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

    def interrupt_response(
      message,
      interruption_id: nil,
      batch_key: nil,
      metadata: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil
    )
      entrypoint = @interruption_mutex.synchronize do
        case @interruption_state
        when :not_started, :starting
          raise AgentInterruptError, "Run entrypoint is not ready for interruptions"
        when :terminal
          raise AgentInterruptError, "Run has already finished"
        end

        @entrypoint
      end
      unless entrypoint.respond_to?(:interrupt_response)
        raise AgentInterruptError, "Run entrypoint does not support interruptions"
      end

      entrypoint.interrupt_response(
        message,
        interruption_id:,
        batch_key:,
        metadata:,
        cancellation_token:,
        deadline:
      )
    end

    def context(state: {}, metadata: {})
      RunContext.new(
        state:,
        cancellation_token:,
        deadline: invocation.deadline_at,
        instrumentation: runtime.instrumentation,
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
        entrypoint_kind: workflow_entrypoint? ? :workflow : :agent,
        workflow_name: workflow_entrypoint? ? entrypoint_name : nil,
        trace_context: invocation[:parent_trace_context],
        trace_links: invocation[:trace_links],
        diagnostic: {input: diagnostic_invocation_message}
      )
      emit(:run_start, run_id: invocation.run_id, thread_id: invocation.session_id) { |event| yield event }
      trace_context = runtime.instrumentation.trace_context(operation_id:) if runtime.instrumentation.respond_to?(:trace_context)
      emit(:trace_context, context: trace_context) { |event| yield event } unless trace_context.nil? || trace_context.empty?
      session_entrypoint = runtime.entrypoint if entrypoint_class <= Agent
      @session = if session_entrypoint&.respond_to?(:open_session)
        session_entrypoint.open_session(self)
      else
        runtime.open_session(self)
      end
      agent = if entrypoint_class <= Agent
        runtime.build_agent(entrypoint_class, run: self)
      else
        runtime.build_entrypoint(run: self)
      end
      @interruption_mutex.synchronize do
        @entrypoint = agent
      end
      register(agent)
      invoke = lambda do
        history = session ? session.history(fallback: invocation.history) : invocation.history
        context = session ? session.state.merge(invocation.context) : invocation.context.dup
        options = {
          history:,
          context:,
          settings: invocation.settings,
          template_locals: runtime.template_locals(run: self, agent:),
          template_paths: Array(invocation[:template_paths]),
          cancellation_token:,
          deadline: invocation.deadline_at,
          parent_operation_id: operation_id,
          checkpoint: lambda do |messages:, state:, parent_operation_id:|
            session&.checkpoint(messages:, state:, parent_operation_id:)
          end
        }
        if agent.is_a?(Agent)
          options[:interrupt_ready] = lambda do
            @interruption_mutex.synchronize { @interruption_state = :active }
          end
        else
          @interruption_mutex.synchronize { @interruption_state = :active }
        end

        agent.stream(invocation.message, **options).each do |event|
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
          message: cleanup_failed ? cleanup_error_message(caught) : error_message(caught),
          cleanup_failed:
        }
      ]
    ensure
      @interruption_mutex.synchronize do
        @last_entrypoint = @entrypoint
        @entrypoint = nil
        @interruption_state = :terminal
      end
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
      runtime.instrumentation.emit(name, **correlation_attributes, **attributes.compact)
    end

    def correlation_attributes
      {
        operation_id:,
        run_id: invocation.run_id,
        invocation_id: invocation.invocation_id,
        session_id: invocation.session_id,
        agent_id: workflow_entrypoint? ? nil : entrypoint_name,
        workflow_name: workflow_entrypoint? ? entrypoint_name : nil
      }.merge(
        runtime.respond_to?(:instrumentation_attributes) ?
          runtime.instrumentation_attributes(run: self) : {}
      )
        .merge(
          @entrypoint&.respond_to?(:instrumentation_attributes) ?
            @entrypoint.instrumentation_attributes(run: self) : {}
        )
        .compact
    end

    def workflow_entrypoint? = entrypoint_class <= Workflow

    def entrypoint_name
      return entrypoint_class.name.to_s if workflow_entrypoint?

      return @entrypoint.entrypoint_name if @entrypoint&.respond_to?(:entrypoint_name)

      entrypoint_class.agent_id
    end

    def subagent_telemetry(data)
      value = data.fetch(:event)
      event = value[:event] || value["event"]
      attributes = {
        subagent_id: value[:subagent_id] || value["subagent_id"],
        conversation_id: value[:conversation_id] || value["conversation_id"],
        resumed: value[:resumed] || value["resumed"],
        kind: value[:kind] || value["kind"],
        turn: value[:turn] || value["turn"],
        status: value[:status] || value["status"],
        error_type: value[:error_type] || value["error_type"]
      }.compact
      parent_operation_id = value[:parent_operation_id] || value["parent_operation_id"] || operation_id
      case event
      when "factory_failed"
        [:subagent_factory_failed, attributes.merge(parent_operation_id:)]
      when "spawned", "message_queued"
        subagent_operation_id = value[:operation_id] || value["operation_id"]
        return unless subagent_operation_id

        @subagent_started_at[subagent_operation_id] = monotonic_time
        [
          :subagent_start,
          attributes.merge(
            operation_id: subagent_operation_id,
            parent_operation_id:,
            agent_id: attributes[:subagent_id]
          )
        ]
      when "turn_started"
        supplied_operation_id = value[:operation_id] || value["operation_id"]
        return unless supplied_operation_id

        [:subagent_turn_started, attributes.merge(operation_id: supplied_operation_id)]
      when "turn_finished", "turn_failed", "cancelled"
        supplied_operation_id = value[:operation_id] || value["operation_id"]
        return unless supplied_operation_id

        started_at = @subagent_started_at.delete(supplied_operation_id)
        outcome = {"turn_finished" => :completed, "turn_failed" => :error, "cancelled" => :cancelled}.fetch(event)
        [
          :subagent_stop,
          attributes.merge(
            operation_id: supplied_operation_id,
            parent_operation_id:,
            agent_id: attributes[:subagent_id],
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
        attributes = data.slice(:attempt, :delay, :error_code, :http_status, :partial_text)
        [:model_retry, attributes.merge(error_class:).compact]
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
      @interruption_mutex.synchronize { @interruption_state = :starting }
    end

    def close_callback(resource)
      raise ArgumentError, "resource must respond to close or a block must be provided" unless resource&.respond_to?(:close)

      -> { resource.close }
    end

    def cleanup_error_message(error)
      error_message(error)
    rescue
      "The run could not cleanly stop all work."
    end

    def error_message(error)
      entrypoint = @entrypoint || @last_entrypoint
      entrypoint&.respond_to?(:error_message) ? entrypoint.error_message(error, self) : runtime.error_message(error, self)
    end

    def diagnostic_invocation_message
      message = invocation.message
      return message unless message.respond_to?(:text)
      return message.text unless message.text.empty?

      {
        role: message.role,
        content: message.content.map { |block| diagnostic_invocation_content(block) }
      }
    end

    def diagnostic_invocation_content(block)
      case block
      when Content::Text
        {type: "text", text: block.text}
      when Content::Reasoning
        {type: "reasoning", text: block.text}
      when Content::Image
        {type: "image", media_type: block.media_type, bytes: block.data.bytesize}
      when Content::Document
        {type: "document", media_type: block.media_type, name: block.name, bytes: block.data.bytesize}
      when Content::ToolUse
        {type: "tool_use", id: block.id, name: block.name, input: block.input}
      when Content::ToolResult
        {
          type: "tool_result",
          tool_use_id: block.tool_use_id,
          content: block.content.to_s,
          status: block.status
        }
      else
        block.to_s
      end
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
