# frozen_string_literal: true

module LittleGhost
  module CodeMode
    class AgentRuntime # :nodoc:
      State = Struct.new(
        :broker, :session, :mutex, :condition, :active, :closing, :deferred_close, :cleaning, :cleanup_error
      )

      def initialize(agent:, declaration:)
        @agent = agent
        @declaration = declaration.transform_keys(&:to_sym)
        implementation = CodeMode.resolve_engine(@declaration.fetch(:engine, :ruby))
        @engine = implementation.is_a?(Class) ? implementation.new : implementation
        @except = @declaration[:except]
        @limits = @declaration.fetch(:limits, {})
        @sandbox_declaration = @declaration.fetch(:sandbox, :native)
        @catalog_broker = Broker.new(agent:, except: @except)
        @states = {}
        @states_mutex = Mutex.new
        @closed = false
      end

      attr_reader :engine

      def broker = @catalog_broker
      def catalog = @catalog_broker.catalog
      def instructions = engine.instructions(catalog:)

      def execute(source:, context:, **options)
        state = state_for(context)
        with_control(state) do
          bind_broker(state.broker, context)
          with_delivery(state.broker) do
            session_for(state).execute(source:, catalog: state.broker.catalog, context:, **options)
          end
        end
      end

      def wait(context:, **options)
        state = existing_state(context)
        raise ToolError, "there is no active code-mode program" unless state

        with_control(state) do
          bind_broker(state.broker, context)
          with_delivery(state.broker) { session_for(state).wait(context:, **options) }
        end
      end

      def stop(context:, **options)
        state = existing_state(context)
        raise ToolError, "there is no active code-mode program" unless state

        with_control(state) do
          bind_broker(state.broker, context)
          with_delivery(state.broker) { session_for(state).stop(context:, **options) }
        end
      end

      def close(context: nil)
        states = @states_mutex.synchronize do
          selected = if context
            [@states[context]].compact
          else
            @closed = true
            @states.values
          end
          selected.each { |state| state.mutex.synchronize { state.closing = true } }
          selected
        end
        states.reverse_each { |state| close_state(state) }
        @states_mutex.synchronize do
          if context
            @states.delete(context) if states.include?(@states[context])
          else
            states.each { |state| @states.delete_if { |_key, current| current.equal?(state) } }
          end
        end
      end

      private

      def bind_broker(broker, context)
        execution = ExecutionState[:tool_execution]
        trace_context = if execution
          Instrumentation.trace_context(operation_id: execution.operation_id)
        end
        trace_context = execution&.parent_trace_context if trace_context.nil? || trace_context.empty?
        broker.bind(
          context:,
          events: execution&.events || [],
          parent_operation_id: execution&.operation_id,
          parent_trace_context: trace_context
        )
      end

      def with_delivery(broker)
        result = yield
        presentations, artifacts, fallback_references = broker.drain_delivery
        output = result.output
        unless fallback_references.empty?
          fallback = "Artifacts:\n#{fallback_references.join("\n")}"
          output = output.to_s.empty? ? fallback : "#{output}\n\n#{fallback}"
        end
        ProgramResult.new(
          output:,
          value: result.value,
          status: result.status,
          error: result.error,
          artifacts: [*result.artifacts, *artifacts],
          presentation_content: [*result.presentation_content, *presentations]
        )
      rescue
        broker.drain_delivery
        raise
      end

      def state_for(context)
        @states_mutex.synchronize do
          raise ToolError, "code-mode runtime is closed" if @closed

          @states[context] ||= State.new(
            Broker.new(agent: @agent, except: @except),
            nil,
            Mutex.new,
            ConditionVariable.new,
            false,
            false,
            false,
            false,
            nil
          )
        end
      end

      def existing_state(context)
        @states_mutex.synchronize { @states[context] }
      end

      def session_for(state)
        state.session ||= engine.open_session(
          broker: state.broker,
          sandbox_factory: sandbox_factory,
          limits: @limits
        )
      end

      def with_control(state)
        acquired = false
        state.mutex.synchronize do
          raise ToolError, "code-mode session is closing" if state.closing
          raise ToolError, "a code-mode control call is already active" if state.active

          state.active = true
          acquired = true
        end
        yield
      ensure
        if acquired
          session = state.mutex.synchronize do
            state.active = false
            if state.deferred_close
              state.cleaning = true if state.session
              state.session.tap { state.session = nil }
            end
          ensure
            state.condition.broadcast
          end
          close_session(state, session)
        end
      end

      def close_state(state)
        session = state.mutex.synchronize do
          if state.active && brokered_lifecycle_reentry?
            state.deferred_close = true
            raise ToolError, "cannot close code mode from a brokered tool while a program is active"
          end
          state.condition.wait(state.mutex) while state.active || state.cleaning
          raise state.cleanup_error if state.cleanup_error

          state.cleaning = true if state.session
          state.session.tap { state.session = nil }
        end
        close_session(state, session)
      ensure
        state.broker.drain_delivery
      end

      def close_session(state, session)
        return unless session

        session.close
      rescue => error
        state.mutex.synchronize { state.cleanup_error ||= error }
        raise
      ensure
        if session
          state.mutex.synchronize do
            state.cleaning = false
            state.condition.broadcast
          end
        end
      end

      def brokered_lifecycle_reentry?
        execution = ExecutionState[:tool_execution]
        execution && !%w[exec wait stop].include?(execution.tool_use.name)
      end

      def sandbox_factory
        declaration = @sandbox_declaration
        lambda do |workspace:, required_runtime_paths: {}|
          if declaration.respond_to?(:call) && !declaration.is_a?(Symbol)
            declaration.call(workspace:, required_runtime_paths:)
          else
            options = declaration.is_a?(Hash) ? declaration.transform_keys(&:to_sym) : {provider: declaration}
            provider = options.delete(:provider) || :native
            implementation = provider.is_a?(Class) ? provider : Sandbox.resolve_provider(provider)
            policy = Sandbox::Policy.coerce(options.delete(:policy) || {
              files: {root: :read_write},
              network: :none
            })
            options[:policy] = Sandbox::Policy.new(
              files: policy.files,
              runtime_paths: policy.runtime_paths.merge(required_runtime_paths.transform_keys(&:to_sym)),
              root_filesystem: policy.root_filesystem,
              environment: policy.environment,
              network: policy.network
            )
            implementation.new(workspace:, **options)
          end
        end
      end
    end

    class ExecTool < Tool # :nodoc:
      tool_name "exec"
      description <<~TEXT.strip
        Run one fresh code-mode program to orchestrate available tools. The program is observed for up to one minute.
        If it finishes, use the result directly. If it returns still_working, call wait to observe the same program.
      TEXT
      exclusive true
      input_schema(
        type: "object",
        properties: {
          source: {type: "string"},
          max_output_tokens: {type: "integer", minimum: 1}
        },
        required: ["source"],
        additionalProperties: false
      )

      def call(input)
        result = agent.code_mode_runtime.execute(
          source: input.fetch("source"),
          context:,
          **{
            max_output_tokens: input["max_output_tokens"]
          }.compact
        )
        serialize(result)
      end

      private

      def serialize(result)
        value = {
          status: result.status,
          output: result.output,
          value: result.value,
          error: result.error
        }.compact
        Tool::ExecutionResult.new(
          value:,
          content: value,
          status: :success,
          artifacts: result.artifacts,
          presentation_content: result.presentation_content
        )
      end
    end

    class WaitTool < ExecTool # :nodoc:
      tool_name "wait"
      description <<~TEXT.strip
        Observe the active code-mode program for up to one minute. The program keeps running continuously; wait does
        not resume or restart it. Call again only after exec or wait returned still_working.
      TEXT
      input_schema(
        type: "object",
        properties: {
          max_output_tokens: {
            type: "integer", minimum: 1,
            description: "Maximum output tokens returned by this observation."
          }
        },
        additionalProperties: false
      )

      def call(input)
        result = agent.code_mode_runtime.wait(
          context:,
          **{
            max_output_tokens: input["max_output_tokens"]
          }.compact
        )
        serialize(result)
      end
    end

    class StopTool < ExecTool # :nodoc:
      tool_name "stop"
      description "Stop the active code-mode program and return any output produced since the previous observation."
      input_schema(
        type: "object",
        properties: {
          max_output_tokens: {
            type: "integer", minimum: 1,
            description: "Maximum output tokens returned while stopping the program."
          }
        },
        additionalProperties: false
      )

      def call(input)
        result = agent.code_mode_runtime.stop(
          context:,
          **{max_output_tokens: input["max_output_tokens"]}.compact
        )
        serialize(result)
      end
    end
  end
end
