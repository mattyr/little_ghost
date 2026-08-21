# frozen_string_literal: true

require_relative "assembly"

module LittleGhost
  # Coordinates Assembly participants with ordinary Ruby control flow.
  #
  # A workflow is an Assembly whose +perform+ method controls ordering,
  # branching, parallel work, and local variables. Each participant may be an
  # Agent or another coordinated Assembly. The workflow consumes intermediate
  # answers and streams one final participant response.
  #
  # A support workflow can guarantee that research happens before the responder
  # writes the caller-visible answer:
  #
  #   class ResponseWorkflow < LittleGhost::Workflow
  #     private
  #
  #     def perform
  #       evidence = invoke(ResearchAgent).output
  #       invoke CustomerSupportAgent, input: <<~PROMPT
  #         #{input.text}
  #
  #         Research:
  #         #{evidence}
  #       PROMPT
  #     end
  #   end
  #
  #   run = ResponseWorkflow.ask("Why is transfer 481 pending?")
  #   run.response
  #   # One possible response: Transfer 481 is waiting for the receiving bank.
  #
  # Call a named Workflow with
  # ask[rdoc-ref:LittleGhost::Assembly.ask] for its final Run, or
  # the streaming entrypoint[rdoc-ref:LittleGhost::Assembly.stream_ask] for live
  # events.
  #
  # +invoke+ returns a lazy Workflow::Invocation. Reading +output+ consumes an
  # intermediate invocation and returns RunResult#output; +perform+ must return
  # its final invocation without consuming it so those events reach the caller.
  # Intermediate usage is added to the final result.
  #
  # A child receives the Workflow input unless +invoke+ supplies another one.
  # It also inherits history, settings, cancellation, deadline, template paths,
  # and the parent tracing relationship. JSON-like context is copied for each
  # child, preventing one intermediate Agent from mutating a sibling's state.
  # Non-JSON-like workflow context raises ArgumentError.
  #
  # A Workflow instance streams once. Returning the wrong value, returning an
  # already consumed invocation, or consuming one twice raises ProtocolError.
  # A composition error fails the owning top-level Run. Each child Assembly
  # closes after its attempt, and a cleanup failure raises from that attempt.
  class Workflow < Assembly
    # Hold one lazy Assembly call inside a workflow composition.
    # Workflow implementations normally use only its output method or return the
    # object as the final invocation.
    class Invocation
      attr_reader :result # :nodoc:

      def initialize(reference:, participant:, input:, history:, context:, policies:, owner:) # :nodoc:
        @reference = reference
        @participant = participant
        @input = input
        @history = history
        @context = context
        @policies = policies
        @owner = owner
        @mutex = Mutex.new
        @consumed = false
        @closed = false
      end

      def each(checkpoint: nil) # :nodoc:
        return enum_for(__method__, checkpoint:) unless block_given?

        @mutex.synchronize do
          raise Error, "workflow invocation is already closed" if @closed
          raise ProtocolError, "workflow invocation was already consumed" if @consumed

          @consumed = true
        end
        execution = @owner.send(
          :execute_workflow_invocation,
          reference: @reference,
          participant: @participant,
          input: @input,
          history: @history,
          context: @context,
          policies: @policies,
          checkpoint:
        ) { |event| yield event }
        @result = execution.result
        @step = execution.step
        @steps = execution.result.steps
        execution.events.each do |event|
          yield event
        end
        @result
      end

      # Consumes this invocation when necessary and returns RunResult#output.
      #
      # A structured agent returns its validated value; an ordinary agent returns
      # response text. Intermediate usage is recorded for the workflow total.
      def output
        @intermediate = true
        unless consumed?
          each do |event|
            @owner.send(:emit_workflow_event, event) if event.type.to_s.start_with?("assembly_")
          end
          @owner.send(:record_workflow_steps, @steps)
        end
        result&.output
      end

      def consumed? # :nodoc:
        @mutex.synchronize { @consumed }
      end

      def close # :nodoc:
        @mutex.synchronize do
          return if @closed

          @closed = true
        end
      end
    end

    # Run that owns this run-scoped Workflow.
    attr_reader :run
    # Runtime used to resolve child Assemblies.
    attr_reader :runtime

    def initialize(run: nil, runtime: nil) # :nodoc:
      super(run:, runtime:, standalone: run.nil?)
      @mutex = Mutex.new
      @closed = false
      @started = false
      @invocations = []
    end

    # Additional prompt locals shared by agents invoked from the workflow.
    # Subclasses may override this hook.
    def prompt_locals = {}

    # Streams the workflow once as StreamEvent objects.
    #
    # +perform+ must return a final, unconsumed Workflow::Invocation. The returned
    # Enumerator is lazy, but calling +stream+ reserves the single-use workflow
    # instance even when enumeration has not started yet.
    def stream(
      input = nil,
      history: nil,
      context: nil,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      settings: nil,
      template_locals: nil,
      template_paths: nil,
      parent_operation_id: nil,
      checkpoint: nil
    )
      raise ArgumentError, "input is required" if input.nil?

      if standalone?
        return build_run(entrypoint_payload(input, {
          history:,
          context:,
          settings:,
          template_paths:,
          deadline_at: deadline,
          cancellation_token:
        }.compact)).each
      end

      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed
        raise Error, "workflow instances can only be streamed once" if @started

        @started = true
        @input = input.is_a?(Message) ? input : Message.new(role: :user, content: input)
        @history = normalize_history(history)
        @context = context || {}
        @cancellation_token = cancellation_token
        @deadline = deadline
        @settings = settings || {}
        @template_locals = template_locals || {}
        @template_paths = template_paths || []
        @parent_operation_id = parent_operation_id
        @checkpoint = checkpoint
        @intermediate_usage = Usage.new
        @workflow_steps = []
        @workflow_events = nil
      end

      Enumerator.new do |events|
        error_emitted = false
        observed_usage = nil
        @workflow_events = events
        ensure_open!
        final_invocation = perform
        unless final_invocation.is_a?(Invocation) && !final_invocation.consumed?
          raise ProtocolError, "#{self.class} must return its final invoke from perform"
        end

        final_invocation.each(checkpoint: @checkpoint) do |event|
          error_emitted = true if event.type == :invocation_error
          event = aggregate_usage(event)
          observed_usage = case event.type
          when :invocation_stop
            event.data.fetch(:result).usage
          when :invocation_error
            event.data[:usage] || observed_usage
          when :assembly_step_error
            event.data[:usage] || observed_usage
          else
            observed_usage
          end
          events << event
        end
      rescue => error
        unless error_emitted
          events << StreamEvent.build(
            :invocation_error,
            error:,
            usage: observed_usage || workflow_usage,
            metadata: {}
          )
        end
        raise
      ensure
        @workflow_events = nil
      end
    end

    # Closes all declared invocations in reverse order.
    #
    # The operation is idempotent, attempts every close, and raises the first
    # cleanup failure.
    def close
      invocations = @mutex.synchronize do
        return if @closed

        @closed = true
        @invocations.reverse
      end
      errors = []
      invocations.each do |invocation|
        invocation.close
      rescue => error
        errors << error
      end
      raise errors.first if errors.any?
    end

    private

    # The current normalized input, frozen history, and JSON-like context exposed
    # to workflow implementations.
    # :doc:
    attr_reader :input, :history, :context

    # :doc:
    # Implements the composition and returns its final unconsumed invocation.
    # Subclasses must override this hook.
    def perform
      raise AbstractMethodError, "#{self.class} must implement #perform"
    end

    # :doc:
    # Creates a lazy invocation for +assembly+.
    #
    # Intermediate calls may use +output+; the final call must be returned from
    # +perform+ without being consumed. +as+ supplies the participant name used
    # in steps and telemetry. Retries default to zero; a positive +retries+
    # value requires explicit exception classes in +retry_on+.
    def invoke(
      assembly,
      as: nil,
      input: self.input,
      history: self.history,
      context: self.context,
      timeout: nil,
      retries: 0,
      retry_on: nil,
      retry_delay: 0
    )
      participant = as || assembly_identity(assembly)
      invocation = Invocation.new(
        reference: assembly,
        participant:,
        input:,
        history:,
        context: isolated_state(context),
        policies: {timeout:, retries:, retry_on:, retry_delay:},
        owner: self
      )
      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed

        @invocations << invocation
      end
      invocation
    end

    # :doc:
    # Consumes independent invocations concurrently and returns their outputs in
    # declaration order.
    #
    # +max_concurrency+ bounds active child executions. A child failure cancels
    # siblings cooperatively before the error is raised.
    def parallel(*invocations, max_concurrency: 8)
      raise ArgumentError, "parallel requires at least one invocation" if invocations.empty?
      unless invocations.all? { |invocation| invocation.is_a?(Invocation) && !invocation.consumed? }
        raise ArgumentError, "parallel accepts unconsumed workflow invocations"
      end

      token = @cancellation_token.child
      queue = SizedQueue.new(1_000)
      worker = task_runner.spawn do
        results = Support::Executor.new(max_concurrency:, runner: task_runner).map(
          invocations,
          cancellation_token: token,
          on_result: ->(_index, execution) { record_workflow_steps(execution.fetch(:steps)) }
        ) do |invocation|
          invocation.each do |event|
            if event.type.to_s.start_with?("assembly_")
              enqueue_assembly_event(queue, [:event, event], token)
            end
          end
          {output: invocation.result&.output, steps: invocation.instance_variable_get(:@steps)}
        end
        enqueue_assembly_event(queue, [:done, results], token)
      rescue => error
        token.cancel
        enqueue_assembly_terminal(queue, [:error, error])
      end
      executions = loop do
        type, value = queue.pop
        emit_workflow_event(value) if type == :event
        raise value if type == :error
        break value if type == :done
      end
      executions.map { |execution| execution.fetch(:output) }
    ensure
      token&.cancel
      worker&.wait
    end

    def execute_workflow_invocation(reference:, participant:, input:, history:, context:, policies:, checkpoint:)
      step_id = SecureRandom.uuid
      predecessor_id = @mutex.synchronize do
        @workflow_steps.reverse.find { |step| step.parent_id.nil? }&.id
      end
      yield StreamEvent.build(
        :assembly_step_start,
        assembly_id: self.class.assembly_id,
        assembly_kind: :workflow,
        participant: participant.to_s,
        step_id:
      )
      execution = execute_assembly_step(
        reference:,
        participant:,
        input:,
        history:,
        context:,
        cancellation_token: @cancellation_token,
        deadline: @deadline,
        settings: @settings,
        template_locals: @template_locals,
        template_paths: @template_paths,
        parent_operation_id: @parent_operation_id,
        policies:,
        predecessor_ids: Array(predecessor_id),
        checkpoint:,
        step_id:
      ) { |event| yield event }
      yield StreamEvent.build(
        :assembly_step_stop,
        assembly_id: self.class.assembly_id,
        assembly_kind: :workflow,
        participant: participant.to_s,
        step_id: execution.step.id,
        usage: execution.step.usage
      )
      execution
    end

    def record_workflow_steps(steps)
      @mutex.synchronize do
        @workflow_steps.concat(steps)
        @intermediate_usage += steps.first.usage
      end
    end

    def emit_workflow_event(event)
      sink = @mutex.synchronize do
        if event.type == :assembly_step_error && event.data[:terminal] && event.data[:usage]
          @intermediate_usage += event.data.fetch(:usage)
        end
        @workflow_events
      end
      sink << event if sink
    end

    def assembly_identity(reference)
      case reference
      when AssemblyBuilder, AssemblyDefinition
        reference.assembly_id
      when Class
        (reference <= Assembly) ? reference.assembly_id : reference.to_s
      else
        reference.to_s
      end
    end

    def aggregate_usage(event)
      case event.type
      when :invocation_stop
        result = event.data.fetch(:result)
        combined = RunResult.new(
          message: result.message,
          stop_reason: result.stop_reason,
          usage: workflow_usage + result.usage,
          messages: result.messages,
          state: result.state,
          structured_result: result.structured_result,
          steps: workflow_steps + result.steps
        )
        StreamEvent.build(event.type, **event.data.merge(result: combined))
      when :invocation_error
        usage = event.data[:usage]
        return event unless usage

        StreamEvent.build(event.type, **event.data.merge(usage: workflow_usage + usage))
      when :assembly_step_error
        usage = event.data[:usage]
        return event unless usage

        StreamEvent.build(event.type, **event.data.merge(usage: workflow_usage + usage))
      else
        event
      end
    end

    def template_locals_for(agent)
      @template_locals.merge(runtime.template_locals(run:, agent:))
    end

    def isolated_state(value)
      case value
      when Hash
        value.to_h { |key, item| [isolated_state(key), isolated_state(item)] }
      when Array
        value.map { |item| isolated_state(item) }
      when String
        value.dup
      when NilClass, TrueClass, FalseClass, Numeric, Symbol
        value
      else
        raise ArgumentError, "workflow context must contain only JSON-like state"
      end
    end

    def workflow_usage
      @mutex.synchronize { @intermediate_usage }
    end

    def workflow_steps
      @mutex.synchronize { @workflow_steps.dup.freeze }
    end

    def ensure_open!
      @mutex.synchronize { raise Error, "workflow is already closed" if @closed }
    end

    def normalize_history(value)
      return [].freeze if value.nil?

      Array(value).map { |message| Message.coerce(message) }.freeze
    end
  end
end
