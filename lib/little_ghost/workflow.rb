# frozen_string_literal: true

module LittleGhost
  class Workflow
    UNSET = Object.new.freeze

    class Invocation
      attr_reader :result

      def initialize(input:, history:, context:, build:, on_usage:)
        @input = input
        @history = history
        @context = context
        @build = build
        @on_usage = on_usage
        @mutex = Mutex.new
        @consumed = false
        @closed = false
      end

      def each(checkpoint: nil)
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

      def output
        @intermediate = true
        each {} unless consumed?
        result&.output
      end

      def consumed?
        @mutex.synchronize { @consumed }
      end

      def close
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

    attr_reader :run

    def initialize(run:)
      @run = run
      @mutex = Mutex.new
      @closed = false
      @started = false
      @invocations = []
    end

    def prompt_locals = {}

    def stream(
      input = UNSET,
      history: UNSET,
      context: UNSET,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      settings: UNSET,
      template_locals: UNSET,
      template_paths: UNSET,
      parent_operation_id: nil,
      checkpoint: nil
    )
      raise ArgumentError, "input is required" if input.equal?(UNSET)

      @mutex.synchronize do
        raise Error, "workflow is already closed" if @closed
        raise Error, "workflow instances can only be streamed once" if @started

        @started = true
        @input = input.is_a?(Message) ? input : Message.new(role: :user, content: input)
        @history = normalize_history(history)
        @context = context.equal?(UNSET) ? {} : context
        @cancellation_token = cancellation_token
        @deadline = deadline
        @settings = settings.equal?(UNSET) ? {} : settings
        @template_locals = template_locals.equal?(UNSET) ? {} : template_locals
        @template_paths = template_paths.equal?(UNSET) ? [] : template_paths
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

    attr_reader :input, :history, :context

    def perform
      raise NotImplementedError, "#{self.class} must implement #perform"
    end

    def invoke(agent_class_or_name, input: self.input, history: self.history, context: self.context)
      invocation = Invocation.new(
        input:,
        history:,
        context: isolated_state(context),
        build: lambda {
          agent = run.application.build_agent(agent_class_or_name, run:)
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
      @template_locals.merge(run.application.template_locals(run:, agent:))
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
      return [].freeze if value.equal?(UNSET)

      Array(value).map { |message| Message.coerce(message) }.freeze
    end
  end
end
