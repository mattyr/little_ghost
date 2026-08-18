# frozen_string_literal: true

module LittleGhost
  module CodeMode
    class AgentRuntime # :nodoc:
      State = Struct.new(:broker, :session, :mutex)

      def initialize(agent:, declaration:)
        @agent = agent
        @declaration = declaration.transform_keys(&:to_sym)
        implementation = CodeMode.resolve_engine(@declaration.fetch(:engine, :ruby))
        @engine = implementation.is_a?(Class) ? implementation.new : implementation
        @direct_tools = @declaration[:direct_tools]
        @limits = @declaration.fetch(:limits, {})
        @sandbox_declaration = @declaration.fetch(:sandbox, :native)
        @catalog_broker = Broker.new(agent:, direct_tools: @direct_tools)
        @states = {}
        @states_mutex = Mutex.new
      end

      attr_reader :engine

      def broker = @catalog_broker
      def catalog = @catalog_broker.catalog
      def instructions = engine.instructions(catalog:)

      def execute(source:, context:, **options)
        state = state_for(context)
        bind_broker(state.broker, context)
        session_for(state).execute(source:, catalog: state.broker.catalog, context:, **options)
      end

      def wait(context:, **options)
        state = existing_state(context)
        raise ToolError, "there is no active code-mode cell" unless state

        bind_broker(state.broker, context)
        session_for(state).wait(context:, **options)
      end

      def close(context: nil)
        states = @states_mutex.synchronize do
          if context
            [@states.delete(context)].compact
          else
            @states.values.tap { @states.clear }
          end
        end
        states.reverse_each { |state| state.session&.close }
      end

      private

      def bind_broker(broker, context)
        execution = ExecutionState[:tool_execution]
        broker.bind(
          context:,
          events: execution&.events || [],
          parent_operation_id: execution&.operation_id,
          parent_trace_context: execution&.parent_trace_context
        )
      end

      def state_for(context)
        @states_mutex.synchronize do
          @states[context] ||= State.new(
            Broker.new(agent: @agent, direct_tools: @direct_tools),
            nil,
            Mutex.new
          )
        end
      end

      def existing_state(context)
        @states_mutex.synchronize { @states[context] }
      end

      def session_for(state)
        state.mutex.synchronize do
          state.session ||= engine.open_session(
            broker: state.broker,
            sandbox_factory: sandbox_factory,
            limits: @limits
          )
        end
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
      description "Run one fresh code-mode cell to orchestrate available tools."
      exclusive true
      input_schema(
        type: "object",
        properties: {
          source: {type: "string"},
          yield_time_ms: {type: "integer", minimum: 1},
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
            yield_time_ms: input["yield_time_ms"],
            max_output_tokens: input["max_output_tokens"]
          }.compact
        )
        serialize(result)
      end

      private

      def serialize(result)
        {
          status: result.status,
          output: result.output,
          value: result.value,
          error: result.error
        }.compact
      end
    end

    class WaitTool < ExecTool # :nodoc:
      tool_name "wait"
      description "Resume or terminate a yielded code-mode cell."
      input_schema(
        type: "object",
        properties: {
          yield_time_ms: {type: "integer", minimum: 1},
          max_output_tokens: {type: "integer", minimum: 1},
          terminate: {type: "boolean"}
        },
        additionalProperties: false
      )

      def call(input)
        result = agent.code_mode_runtime.wait(
          context:,
          **{
            yield_time_ms: input["yield_time_ms"],
            max_output_tokens: input["max_output_tokens"],
            terminate: input.fetch("terminate", false)
          }.compact
        )
        serialize(result)
      end
    end
  end
end
