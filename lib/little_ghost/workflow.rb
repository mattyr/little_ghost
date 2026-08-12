# frozen_string_literal: true

module LittleGhost
  # Build agentic workflows with ordinary Ruby branching and local variables.
  # A workflow composes several agents, consumes intermediate answers, and
  # streams one final agent response.
  #
  # A support workflow can route a difficult request through research before the
  # responder writes the caller-visible answer:
  #
  #   class ResponseWorkflow < LittleGhost::Workflow
  #     private
  #
  #     def perform
  #       route = invoke(RouterAgent).output
  #       return invoke(CustomerSupportAgent) unless route["research"]
  #
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
  #   run = runtime.build_run(
  #     {message: "Why is transfer 481 pending?"},
  #     agent_class: CustomerSupportAgent,
  #     entrypoint_class: ResponseWorkflow
  #   ).call
  #   run.response # => "Transfer 481 is waiting for the receiving bank."
  #
  # +invoke+ returns a lazy Workflow::Invocation. Reading +output+ consumes an
  # intermediate invocation and returns RunResult#output; +perform+ must return
  # its final invocation without consuming it so those events reach the caller.
  # Intermediate usage is added to the final result.
  #
  # Every child inherits input, history, settings, cancellation, deadline,
  # template paths, and trace parentage unless +invoke+ overrides its input.
  # JSON-like context is copied for each child, preventing one intermediate agent
  # from mutating a sibling's state. Non-JSON-like workflow context raises
  # ArgumentError.
  #
  # A workflow instance streams once. Returning the wrong value, returning an
  # already consumed invocation, or consuming an invocation twice raises
  # ProtocolError. Built agents close in reverse order, and the first cleanup
  # failure is re-raised after every invocation has been given a chance to close.
  # Composition errors emit an +invocation_error+ event and then re-raise.
  class Workflow
    # Hold one lazy agent call inside a workflow composition.
    # Workflow implementations normally use only its output method or return the
    # object as the final invocation.
    class Invocation
      attr_reader :result # :nodoc:

      def initialize(input:, history:, context:, build:, on_usage:) # :nodoc:
        @input = input
        @history = history
        @context = context
        @build = build
        @on_usage = on_usage
        @mutex = Mutex.new
        @consumed = false
        @closed = false
      end

      def each(checkpoint: nil) # :nodoc:
        return enum_for(__method__, checkpoint:) unless block_given?

        agent, options = @mutex.synchronize do
          raise Error, "workflow invocation is already closed" if @closed
          raise ProtocolError, "workflow invocation was already consumed" if @consumed

          @consumed = true
          @agent, options = @build.call
          [@agent, options]
        end
        begin
          agent.stream(
            @input,
            history: @history,
            context: @context,
            **options,
            checkpoint:
          ).each do |event|
            @result = event.data[:result] if event.type == :invocation_stop
            @usage = event.data[:usage] if event.type == :invocation_error
            yield event
          end
        ensure
          report_usage if @intermediate
          close
        end
      end

      # Consumes this invocation when necessary and returns RunResult#output.
      #
      # A structured agent returns its validated value; an ordinary agent returns
      # response text. Intermediate usage is recorded for the workflow total.
      def output
        @intermediate = true
        each {} unless consumed?
        result&.output
      end

      def consumed? # :nodoc:
        @mutex.synchronize { @consumed }
      end

      def close # :nodoc:
        agent = @mutex.synchronize do
          return if @closed

          @closed = true
          @agent
        end
        agent&.close
      end

      private

      def report_usage
        usage = result&.usage || @usage
        @on_usage.call(usage) if usage
      end
    end

    # Owning run and the runtime used to resolve workflow agents.
    attr_reader :run, :runtime

    def initialize(run:, runtime: run.runtime) # :nodoc:
      @run = run
      @runtime = runtime
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
      end

      Enumerator.new do |events|
        error_emitted = false
        observed_usage = nil
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
      end
    end

    # Closes all built agent invocations in reverse order.
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
    # Creates a lazy invocation for +agent_class_or_name+.
    #
    # Intermediate calls may use +output+; the final call must be returned from
    # +perform+ without being consumed.
    def invoke(agent_class_or_name, input: self.input, history: self.history, context: self.context)
      invocation = Invocation.new(
        input:,
        history:,
        context: isolated_state(context),
        build: lambda {
          agent = runtime.build_agent(agent_class_or_name, run:)
          begin
            [
              agent,
              {
                cancellation_token: @cancellation_token,
                deadline: @deadline,
                settings: @settings,
                template_locals: template_locals_for(agent),
                template_paths: @template_paths,
                parent_operation_id: @parent_operation_id
              }
            ]
          rescue
            agent.close
            raise
          end
        },
        on_usage: ->(usage) { record_intermediate_usage(usage) }
      )
      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed

        @invocations << invocation
      end
      invocation
    end

    def record_intermediate_usage(usage)
      @mutex.synchronize { @intermediate_usage += usage }
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
          structured_result: result.structured_result
        )
        StreamEvent.build(event.type, **event.data.merge(result: combined))
      when :invocation_error
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

    def ensure_open!
      @mutex.synchronize { raise Error, "workflow is already closed" if @closed }
    end

    def normalize_history(value)
      return [].freeze if value.nil?

      Array(value).map { |message| Message.coerce(message) }.freeze
    end
  end
end
