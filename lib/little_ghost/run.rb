# frozen_string_literal: true

require "securerandom"

module LittleGhost
  # Observe one top-level assembly execution from start to finish.
  # A run records its response, outcome, usage, error, and owned resources.
  #
  #   run = CustomerSupportAgent.ask("Why is transfer 481 pending?")
  #
  #   run.completed? # => true
  #   run.outcome    # => "completed"
  #   run.response   # => "Transfer 481 is waiting for the receiving bank."
  #
  # +ask+ returns the Run after work finishes. +stream_ask+ yields StreamEvent
  # objects as work happens, then returns the same finished Run. A Run executes
  # only once.
  #
  #   stream = CustomerSupportAgent.stream_ask("Where is transfer 481?")
  #   run = stream.each do |event|
  #     publish(event) if event.type == :text_delta
  #   end
  #
  #   run.completed? # => true
  #   run.response
  #
  # == Outcomes
  #
  # Completion, failure, deadline, and cancellation become the +completed+,
  # +failed+, +partial+, and +cancelled+ outcomes. Ordinary execution failures
  # are available through +error+ and the terminal stream event. Failures while
  # closing resources, delivering events, or reporting instrumentation may
  # still raise because LittleGhost cannot report a reliable ending.
  #
  # Tool validation and ToolError failures return safe Tool results to the model,
  # which may recover and complete the Run. Input, configuration, or resource
  # construction can raise before a Run exists. Once execution begins, terminal
  # events are +run_stop+, +run_error+, +run_partial+, and +run_cancel+.
  #
  # == Owned resources
  #
  # The Run opens its workspace, sandbox, Session, and Assembly entrypoint, then
  # closes registered resources in reverse order. +register+ adds application
  # resources to that cleanup sequence. Interjection is available only while one
  # Agent entrypoint is active.
  #
  # == Nested Agent events
  #
  # A composite Assembly stream observes every Agent that shares the Run. Each
  # +:agent_stream+ event carries an AgentStreamSource in +data[:source]+ and a
  # copied, frozen Agent StreamEvent in +data[:event]+. An inner
  # +:invocation_start+ also includes the copied, frozen Message sent to that
  # Agent in +data[:input]+. Event consumers cannot change the running work.
  #
  # Parallel Agents may interleave, but the Run invokes the stream consumer
  # serially. Contextual events expose data from every participating Agent, so
  # applications should enable +include_agent_events+ only for destinations
  # that may see every participant's data.
  class Run
    include Enumerable

    # Runtime that built and executes this Run.
    attr_reader :runtime
    # Agent class used for compatibility when the entrypoint is an Agent.
    attr_reader :agent_class
    # Public Agent, Workflow, Swarm, or Graph class selected by the caller.
    attr_reader :entrypoint_class
    # Normalized request carried by this Run.
    attr_reader :invocation
    # Token that cooperatively stops this Run and its children.
    attr_reader :cancellation_token
    # Final RunResult, when the Assembly produced one.
    attr_reader :result
    # Unique identifier for this top-level operation.
    attr_reader :operation_id
    # Terminal String: +completed+, +failed+, +partial+, or +cancelled+.
    attr_reader :outcome
    # Caller-facing final text, or the partial text preserved at a deadline.
    attr_reader :response
    # Exception that caused a failed, partial, or cancelled outcome.
    attr_reader :error
    # Session opened for this invocation, when persistence is configured.
    attr_reader :session
    # Normalized Usage accumulated by the Run.
    attr_reader :usage
    # Request-scoped workspace owned or supplied by the Run.
    attr_reader :workspace
    # Request-scoped sandbox owned or supplied by the Run.
    attr_reader :sandbox

    # Creates a dormant run for +invocation+.
    def initialize(invocation:, runtime:, agent_class: nil, assembly_class: nil, entrypoint_class: nil,
      execution_class: nil,
      cancellation_token: Support::CancellationToken.new, workspace: nil, sandbox: nil,
      include_agent_events_by_default: false)
      entrypoint_class ||= assembly_class || agent_class
      raise ArgumentError, "entrypoint_class is required" unless entrypoint_class
      execution_class ||= assembly_class || entrypoint_class

      @runtime = runtime
      @agent_class = agent_class
      @entrypoint_class = entrypoint_class
      @execution_class = execution_class
      @invocation = invocation
      @cancellation_token = cancellation_token
      @workspace = workspace
      @sandbox = sandbox
      @operation_id = SecureRandom.uuid
      @resources = []
      @shared_resources = {}
      @shared_resource_condition = ConditionVariable.new
      @closed = false
      @started = false
      @mutex = Mutex.new
      @event_mutex = Mutex.new
      @subagent_instrumentation_mutex = Mutex.new
      @subagent_instrumentation = {}
      @assembly_step_instrumentation_mutex = Mutex.new
      @assembly_step_instrumentation = {}
      @exclusive_tools_mutex = Mutex.new
      @once_mutex = Mutex.new
      @once_keys = {}
      @interjection_mutex = Mutex.new
      @interjection_condition = ConditionVariable.new
      @interjection_state = :not_started
      @active_interjections = 0
      @entrypoint = nil
      @usage = Usage.new
      include_agent_events = invocation[:include_agent_events]
      unless include_agent_events.nil? || include_agent_events == true || include_agent_events == false
        raise InvocationError, "include_agent_events must be true or false"
      end
      @include_agent_events = include_agent_events.nil? ? include_agent_events_by_default : include_agent_events
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
      @emitter = lambda do |event|
        @event_mutex.synchronize { yield_event(event) { |value| yield value } }
      end
      Instrumentation.with_context(correlation_attributes.except(:operation_id)) do
        execute { |event| @emitter.call(event) }
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

    # Indicates whether the stream includes contextual events from every Agent
    # that executes as part of this Run.
    def include_agent_events? = @include_agent_events

    # Adds an interjection to the active entrypoint and waits for its response.
    #
    # Raises LittleGhost::AgentInterjectionError before the entrypoint is ready,
    # after it finishes, or when the entrypoint does not support interjections.
    def interject(
      message,
      interjection_id: nil,
      batch_key: nil,
      metadata: {},
      cancellation_token: Support::CancellationToken.new,
      deadline: nil
    )
      interject_with do
        [
          message,
          {
            interjection_id:,
            batch_key:,
            metadata:,
            cancellation_token:,
            deadline:
          }
        ]
      end
    end

    def interject_with # :nodoc:
      entrypoint = @interjection_mutex.synchronize do
        case @interjection_state
        when :not_started, :starting
          raise AgentInterjectionError, "Run entrypoint is not ready for interjections"
        when :terminal
          raise AgentInterjectionError, "Run has already finished"
        end

        @active_interjections += 1
        @entrypoint
      end
      unless entrypoint.respond_to?(:interject)
        raise AgentInterjectionError, "Run entrypoint does not support interjections"
      end

      message, options = yield
      entrypoint.interject(message, **options)
    ensure
      if entrypoint
        @interjection_mutex.synchronize do
          @active_interjections -= 1
          @interjection_condition.broadcast
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
      @emitter&.call(event)
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

    def shared_resource(key) # :nodoc:
      raise ArgumentError, "shared_resource requires a block" unless block_given?

      entry = @mutex.synchronize do
        loop do
          raise Error, "run is already closed" if @closed

          existing = @shared_resources[key]
          if existing
            return existing.fetch(:value) if existing[:ready]

            @shared_resource_condition.wait(@mutex)
            next
          end

          created = {ready: false, value: nil}
          @shared_resources[key] = created
          break created
        end
      end

      value = yield
      @mutex.synchronize do
        unless @shared_resources[key].equal?(entry) && !@closed
          raise Error, "run closed while a shared resource was starting"
        end

        entry[:value] = value
        entry[:ready] = true
        @shared_resource_condition.broadcast
      end
      value
    rescue
      @mutex.synchronize do
        @shared_resources.delete(key) if @shared_resources[key].equal?(entry)
        @shared_resource_condition.broadcast
      end
      raise
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

    def prepare_interjection(payload) # :nodoc:
      runtime.prepare_interjection(self, payload)
    end

    # Closes registered resources in reverse order.
    #
    # The operation is idempotent. It attempts every closer and then raises the
    # first LittleGhost::CleanupError, or otherwise the first cleanup exception.
    def close
      callbacks = @mutex.synchronize do
        return if @closed
        @closed = true
        @shared_resources.clear
        @shared_resource_condition.broadcast
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
        finish_remaining_assembly_step_instrumentation(
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
        entrypoint_kind:,
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
      runtime.prepare_execution(self) if runtime.respond_to?(:prepare_execution)
      @session = runtime.open_session(self)
      agent = runtime.build_assembly(@execution_class, run: self)
      @interjection_mutex.synchronize do
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
          options[:interject_ready] = lambda do
            @interjection_mutex.synchronize { @interjection_state = :active }
          end
        else
          @interjection_mutex.synchronize { @interjection_state = :active }
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
      @interjection_mutex.synchronize do
        @interjection_state = :terminal
        @interjection_condition.wait(@interjection_mutex) while @active_interjections.positive?
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
      attributes = {
        operation_id:,
        run_id: invocation.run_id,
        invocation_id: invocation.invocation_id,
        session_id: invocation.session_id,
        service_name: runtime.service_name
      }
      case entrypoint_kind
      when :agent
        attributes[:agent_id] = entrypoint_name
      when :workflow
        attributes[:workflow_name] = entrypoint_name
      else
        attributes[:assembly_id] = entrypoint_name
        attributes[:assembly_kind] = entrypoint_kind
      end
      attributes
    end

    def workflow_run? = defined?(Workflow) && entrypoint_class <= Workflow

    def entrypoint_kind
      return entrypoint_class.assembly_kind if entrypoint_class.respond_to?(:assembly_kind)

      workflow_run? ? :workflow : :agent
    end

    def entrypoint_name
      return entrypoint_class.name.to_s if workflow_run?

      return @entrypoint.entrypoint_name if @entrypoint&.respond_to?(:entrypoint_name)

      entrypoint_class.respond_to?(:assembly_id) ? entrypoint_class.assembly_id : entrypoint_class.name.to_s
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
      when :assembly_step_start
        start_assembly_step_instrumentation(data)
      when :assembly_step_stop
        finish_assembly_step_instrumentation(data.fetch(:step_id), data.merge(outcome: :completed))
      when :assembly_step_error
        return unless data[:terminal]

        finish_assembly_step_instrumentation(data.fetch(:step_id), data.merge(outcome: :error))
      when :assembly_step_retry, :assembly_fork, :assembly_join, :assembly_transition, :assembly_handoff_loop
        instrument(type, data.except(:usage))
      end
    end

    def start_assembly_step_instrumentation(attributes)
      step_id = attributes.fetch(:step_id)
      handle = Instrumentation.start(
        :assembly_step,
        parent: attributes[:parent_operation_id] || operation_id,
        operation_id: step_id,
        detached: true,
        assembly_id: attributes[:assembly_id],
        assembly_kind: attributes[:assembly_kind],
        participant: attributes[:participant],
        branch_id: attributes[:branch_id]
      )
      @assembly_step_instrumentation_mutex.synchronize { @assembly_step_instrumentation[step_id] = handle }
    end

    def finish_assembly_step_instrumentation(step_id, attributes)
      handle = @assembly_step_instrumentation_mutex.synchronize do
        @assembly_step_instrumentation.delete(step_id)
      end
      return unless handle

      usage = attributes[:usage]
      handle.finish(
        outcome: attributes[:outcome],
        error_type: attributes[:error_type],
        **(usage ? usage_attributes(usage) : {})
      )
    end

    def finish_remaining_assembly_step_instrumentation(outcome:, error_type: nil)
      handles = @assembly_step_instrumentation_mutex.synchronize do
        @assembly_step_instrumentation.values.tap { @assembly_step_instrumentation.clear }
      end
      handles.reverse_each { |handle| handle.finish(outcome:, error_type:) }
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
      @interjection_mutex.synchronize { @interjection_state = :starting }
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
