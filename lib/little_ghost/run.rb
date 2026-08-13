# frozen_string_literal: true

require "securerandom"

module LittleGhost
  # Observe one top-level agent or workflow execution from start to finish.
  # A run records its response, outcome, usage, error, and owned resources.
  #
  #   run = CustomerSupportAgent.ask("Why is transfer 481 pending?")
  #
  #   run.completed? # => true
  #   run.outcome    # => "completed"
  #   run.response   # => "Transfer 481 is waiting for the receiving bank."
  #
  # The class-level ask helper[rdoc-ref:LittleGhost::Agent.ask] or standalone
  # ask method[rdoc-ref:LittleGhost::Agent#ask] consumes the event stream and
  # returns the Run. For a live interface, the class-level streaming
  # helper[rdoc-ref:LittleGhost::Agent.stream_ask] or standalone streaming
  # method[rdoc-ref:LittleGhost::Agent#stream_ask] yields StreamEvent objects
  # and returns the same run after enumeration. A run can execute only once.
  #
  # Completion, failure, deadline, and cancellation become the +completed+,
  # +failed+, +partial+, and +cancelled+ outcomes. Ordinary execution failures
  # are available through +error+ and the terminal stream event; cleanup, event
  # delivery, or instrumentation failures may still raise because the framework
  # cannot safely report a clean stop.
  #
  # The run opens its workspace, sandbox, session, and entrypoint, then closes
  # registered resources in reverse order. +register+ extends that lifecycle for
  # application resources. Interruption is available only while an agent
  # entrypoint is active and unambiguous.
  class Run
    include Enumerable

    # Runtime and declarations used to execute the run; its request, cancellation
    # token, resources, terminal outcome, response, result, usage, and error.
    attr_reader :runtime, :agent_class, :entrypoint_class, :invocation, :cancellation_token, :result, :operation_id,
      :outcome, :response, :error, :session, :usage, :workspace, :sandbox

    # Creates a dormant run for +invocation+.
    def initialize(invocation:, agent_class:, runtime:, entrypoint_class: agent_class,
      cancellation_token: Support::CancellationToken.new, workspace: nil, sandbox: nil)
      @runtime = runtime
      @agent_class = agent_class
      @entrypoint_class = entrypoint_class
      @invocation = invocation
      @cancellation_token = cancellation_token
      @workspace = workspace
      @sandbox = sandbox
      @operation_id = SecureRandom.uuid
      @resources = []
      @closed = false
      @started = false
      @mutex = Mutex.new
      @event_mutex = Mutex.new
      @subagent_instrumentation_mutex = Mutex.new
      @subagent_instrumentation = {}
      @exclusive_tools_mutex = Mutex.new
      @once_mutex = Mutex.new
      @once_keys = {}
      @interruption_mutex = Mutex.new
      @interruption_condition = ConditionVariable.new
      @interruption_state = :not_started
      @active_interruptions = 0
      @entrypoint = nil
      @usage = Usage.new
    end

    # Consumes the event stream and returns +self+.
    def call
      each { |_event| }
      self
    end

    # Yields events and returns +self+ after the terminal event.
    #
    # Without a block, returns an Enumerator. A second execution raises Error.
    def each
      return enum_for(__method__) unless block_given?

      begin_execution!
      @emitter = ->(event) { yield_event(event) { |value| yield value } }
      Instrumentation.with_context(correlation_attributes.except(:operation_id)) do
        execute { |event| yield event }
      end
      self
    ensure
      @emitter = nil
    end

    # True after successful completion.
    def completed? = outcome == "completed"

    # True after execution or cleanup failed.
    def failed? = outcome == "failed"

    # True when the deadline preserved a partial response.
    def partial? = outcome == "partial"

    # True when cancellation stopped the run without a response.
    def cancelled? = outcome == "cancelled"

    # Adds an interruption to the active entrypoint and waits for its response.
    #
    # Raises LittleGhost::AgentInterruptError before the entrypoint is ready,
    # after it finishes, or when the entrypoint does not support interruptions.
    def interrupt_response(
      message,
      interruption_id: nil,
      batch_key: nil,
      metadata: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil
    )
      interrupt_response_with do
        [
          message,
          {
            interruption_id:,
            batch_key:,
            metadata:,
            cancellation_token:,
            deadline:
          }
        ]
      end
    end

    def interrupt_response_with # :nodoc:
      entrypoint = @interruption_mutex.synchronize do
        case @interruption_state
        when :not_started, :starting
          raise AgentInterruptError, "Run entrypoint is not ready for interruptions"
        when :terminal
          raise AgentInterruptError, "Run has already finished"
        end

        @active_interruptions += 1
        @entrypoint
      end
      unless entrypoint.is_a?(Agent)
        raise AgentInterruptError, "Run entrypoint does not support interruptions"
      end

      message, options = yield
      entrypoint.interrupt_response(message, **options)
    ensure
      if entrypoint
        @interruption_mutex.synchronize do
          @active_interruptions -= 1
          @interruption_condition.broadcast
        end
      end
    end

    # Creates a RunContext with this run's cancellation token and deadline.
    def context(state: {}, metadata: {})
      RunContext.new(
        state:,
        cancellation_token:,
        deadline: invocation.deadline_at,
        metadata:
      )
    end

    def publish(type, **data) # :nodoc:
      event = StreamEvent.build(type, **data)
      @event_mutex.synchronize { @emitter&.call(event) }
      instrument_event(type, data)
      event
    end

    # Adds a resource or closer to reverse-order cleanup and returns the resource.
    #
    # A resource must respond to +close+ unless a block supplies the cleanup
    # operation. Registering after the run has closed raises Error.
    def register(resource = nil, &closer)
      callback = closer || close_callback(resource)
      @mutex.synchronize do
        raise Error, "run is already closed" if @closed
        @resources << callback
      end
      resource
    end

    def synchronize_exclusive_tools(&block) # :nodoc:
      @exclusive_tools_mutex.synchronize(&block)
    end

    # Performs the block at most once successfully for +key+ during this run.
    #
    # Concurrent callers are serialized. The caller that performs the block
    # receives its value; later callers receive +nil+. If the block raises, the
    # key is not recorded and a later call may retry it.
    def once(key)
      @once_mutex.synchronize do
        return if @once_keys.key?(key)

        value = yield
        @once_keys[key] = true
        value
      end
    end

    def prepare_interruption(payload) # :nodoc:
      runtime.prepare_interruption(self, payload)
    end

    # Closes registered resources in reverse order.
    #
    # The operation is idempotent. It attempts every closer and then raises the
    # first LittleGhost::CleanupError, or otherwise the first cleanup exception.
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
      cleanup_error = errors.find { |caught| caught.is_a?(CleanupError) } || errors.first
      begin
        finish_remaining_subagent_instrumentation(
          outcome: cleanup_error ? :error : :cancelled,
          error_type: cleanup_error&.class&.name
        )
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
      @instrumentation_handle = Instrumentation.start(
        :run,
        parent: nil,
        **correlation_attributes,
        entrypoint_kind: workflow_run? ? :workflow : :agent,
        workflow_name: workflow_run? ? entrypoint_name : nil,
        trace_context: invocation[:parent_trace_context],
        trace_links: invocation[:trace_links],
        diagnostic: {input: diagnostic_invocation_message}
      )
      emit(:run_start, run_id: invocation.run_id, thread_id: invocation.session_id) { |event| yield event }
      trace_context = Instrumentation.trace_context(operation_id:)
      emit(:trace_context, context: trace_context) { |event| yield event } unless trace_context.nil? || trace_context.empty?
      workspace&.open(run: self)
      sandbox&.open(run: self)
      @session = runtime.open_session(self)
      agent = if entrypoint_class <= Agent
        runtime.build_agent(entrypoint_class, run: self)
      else
        entrypoint_class.new(run: self, runtime:)
      end
      @interruption_mutex.synchronize do
        @entrypoint = agent
      end
      register(agent)
      invoke = lambda do
        history = session ? runtime.session_history(self, session, fallback: invocation.history) : invocation.history
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
        @interruption_state = :terminal
        @interruption_condition.wait(@interruption_mutex) while @active_interruptions.positive?
        @last_entrypoint = @entrypoint
        @entrypoint = nil
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
        @instrumentation_handle&.finish(**correlation_attributes.merge(stop_attributes))
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
      Instrumentation.publish(name, **correlation_attributes.merge(attributes.compact))
    end

    def correlation_attributes
      {
        operation_id:,
        run_id: invocation.run_id,
        invocation_id: invocation.invocation_id,
        session_id: invocation.session_id,
        service_name: runtime.service_name,
        agent_id: workflow_run? ? nil : entrypoint_name,
        workflow_name: workflow_run? ? entrypoint_name : nil
      }.compact
    end

    def workflow_run? = entrypoint_class <= Workflow

    def entrypoint_name
      return entrypoint_class.name.to_s if workflow_run?

      return @entrypoint.entrypoint_name if @entrypoint.is_a?(Agent)

      entrypoint_class.agent_id
    end

    def instrument_subagent(data)
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
        instrument(:subagent_factory_failed, attributes.merge(parent_operation_id:))
      when "spawned", "message_queued"
        subagent_operation_id = value[:operation_id] || value["operation_id"]
        return unless subagent_operation_id

        values = attributes.merge(
          operation_id: subagent_operation_id,
          parent_operation_id:,
          agent_id: attributes[:subagent_id]
        )
        start_subagent_instrumentation(values)
        instrument(:subagent_spawned, values)
      when "turn_started"
        supplied_operation_id = value[:operation_id] || value["operation_id"]
        return unless supplied_operation_id

        instrument(
          :subagent_turn_started,
          attributes.merge(operation_id: supplied_operation_id, parent_operation_id:)
        )
      when "turn_finished", "turn_failed", "cancelled"
        supplied_operation_id = value[:operation_id] || value["operation_id"]
        return unless supplied_operation_id

        outcome = {"turn_finished" => :completed, "turn_failed" => :error, "cancelled" => :cancelled}.fetch(event)
        values = attributes.merge(
          operation_id: supplied_operation_id,
          parent_operation_id:,
          agent_id: attributes[:subagent_id],
          outcome:,
          error_type: (event == "turn_failed") ? attributes[:error_type] || "LittleGhost::SubagentError" : nil
        ).compact
        instrument(:subagent_finished, values)
        finish_subagent_instrumentation(supplied_operation_id, values)
      end
    end

    def instrument_event(type, data)
      case type.to_sym
      when :subagent
        instrument_subagent(data)
      when :model_retry
        error = data[:error]
        error_class = error.class.name if error.is_a?(Exception)
        error_class ||= error if error.is_a?(String) && error.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/)
        attributes = data.slice(:attempt, :delay, :error_code, :http_status, :partial_text)
        instrument(:model_retry, attributes.merge(error_class:).compact)
      end
    end

    def start_subagent_instrumentation(attributes)
      operation_id = attributes.fetch(:operation_id)
      @subagent_instrumentation_mutex.synchronize do
        return if @subagent_instrumentation.key?(operation_id)

        values = correlation_attributes.merge(attributes).except(:operation_id, :parent_operation_id)
        @subagent_instrumentation[operation_id] = Instrumentation.start(
          :subagent,
          parent: attributes.fetch(:parent_operation_id),
          operation_id:,
          detached: true,
          **values
        )
      end
    end

    def finish_subagent_instrumentation(operation_id, attributes)
      handle = @subagent_instrumentation_mutex.synchronize do
        @subagent_instrumentation.delete(operation_id)
      end
      return unless handle

      handle.finish(**attributes.except(:operation_id, :parent_operation_id))
    end

    def finish_remaining_subagent_instrumentation(outcome:, error_type: nil)
      handles = @subagent_instrumentation_mutex.synchronize do
        @subagent_instrumentation.values.tap { @subagent_instrumentation.clear }
      end
      errors = handles.filter_map do |handle|
        handle.finish(outcome:, error_type:)
        nil
      rescue => error
        error
      end
      raise errors.first if errors.any?
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
      runtime.error_message(error, self)
    end

    def diagnostic_invocation_message
      message = invocation.message
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
