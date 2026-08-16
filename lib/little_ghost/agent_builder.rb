# frozen_string_literal: true

module LittleGhost
  class AgentFactory # :nodoc: all
    class ActivityRelay
      def initialize
        @mutex = Mutex.new
        @observers = []
      end

      def subscribe(&observer)
        @mutex.synchronize { @observers << observer }
      end

      def publish
        @mutex.synchronize { @observers.dup }.each(&:call)
      end
    end

    def initialize(runtime:, prompt_paths:, resolve_agent:)
      @runtime = runtime
      @prompt_paths = prompt_paths
      @resolve_agent = resolve_agent
    end

    def build(
      agent_class_or_name,
      run:,
      model: nil,
      tools: [],
      conversation_id: nil,
      agent_path: Subagents::AgentPath::ROOT,
      agent_stream_path: []
    )
      agent_class = @resolve_agent.call(agent_class_or_name)
      build_agent(agent_class, run:, model:, tools:, conversation_id:, agent_path:, agent_stream_path:)
    end

    private

    attr_reader :runtime, :prompt_paths

    def instantiate(agent_class, run:, tools:, model:, delegation_activity:, agent_path:, agent_stream_path:)
      agent_class.new(
        model:,
        runtime:,
        tools:,
        template_paths: prompt_paths,
        run:,
        workspace: run.workspace,
        sandbox: run.sandbox,
        delegation_activity:,
        agent_path:,
        **agent_class.limits
      ).bind_agent_stream_path(agent_stream_path)
    end

    def build_agent(
      agent_class,
      run:,
      model:,
      tools:,
      conversation_id: nil,
      agent_path: Subagents::AgentPath::ROOT,
      agent_stream_path: []
    )
      delegation_activity = ActivityRelay.new
      configured_tools = Array(tools).dup
      configured_tools.concat(
        delegation_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:, agent_stream_path:)
      )
      resolved_model = model || runtime.model_for(agent_class, run)
      transferred = true
      instantiate(
        agent_class,
        run:,
        model: resolved_model,
        tools: configured_tools,
        delegation_activity:,
        agent_path:,
        agent_stream_path:
      )
    rescue
      close_tools(configured_tools) unless transferred
      raise
    end

    def delegation_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:, agent_stream_path:)
      tools = agent_tools(agent_class, run, agent_stream_path:)
      tools.concat(subagent_tools(
        agent_class,
        run,
        conversation_id:,
        delegation_activity:,
        agent_path:,
        agent_stream_path:
      ))
    rescue
      close_tools(tools)
      raise
    end

    def agent_tools(agent_class, run, agent_stream_path:)
      tools = []
      agent_class.assembly_tool_declarations.each do |declaration|
        child = declared_assembly(declaration, run, agent_stream_path:)
        begin
          tools << child.as_tool(
            name: declaration.fetch(:name),
            description: declaration.fetch(:description),
            preserve_context: declaration.fetch(:preserve_context)
          )
        rescue
          child.close
          raise
        end
      end
      tools
    rescue
      close_tools(tools)
      raise
    end

    def declared_assembly(declaration, run, agent_stream_path:)
      assembly_class = declaration.fetch(:assembly)
      if assembly_class.is_a?(AssemblyDefinition) && assembly_class.kind == :agent
        declared_agent(declaration.merge(agent: assembly_class.implementation), run, agent_stream_path:)
      elsif assembly_class <= Agent
        declared_agent(declaration.merge(agent: assembly_class), run, agent_stream_path:)
      else
        runtime.build_assembly(assembly_class, run:, agent_stream_path:)
      end
    end

    def subagent_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:, agent_stream_path:)
      definitions = agent_class.subagent_declarations.map do |declaration|
        Subagents::Definition.new(
          kind: declaration.fetch(:kind),
          description: declaration.fetch(:description),
          persist: declaration.fetch(:persist, true),
          accepts_conversation_id: true,
          factory: lambda do |subagent_id, child_conversation_id = nil|
            factory = declaration[:factory]
            if factory
              invoke_factory(factory, subagent_id, run).tap do |agent|
                agent.bind_agent_stream_path(agent_stream_path) if agent.respond_to?(:bind_agent_stream_path)
              end
            else
              declared_agent(
                declaration,
                run,
                conversation_id: child_conversation_id,
                agent_path: subagent_id,
                agent_stream_path:
              )
            end
          end
        )
      end
      declared_kinds = definitions.map(&:kind)
      agent_class.subagent_resolvers.each do |resolver|
        resolved = Array(resolver.call(run))
        unless resolved.all? { |definition| definition.is_a?(Subagents::Definition) }
          raise ConfigurationError, "Subagent resolvers must return LittleGhost::Subagents::Definition objects"
        end
        definitions.concat(
          resolved
            .reject { |definition| declared_kinds.include?(definition.kind) }
            .map { |definition| stream_bound_definition(definition, agent_stream_path) }
        )
      end
      return [] if definitions.empty?

      Subagents::Manager.new(
        definitions,
        runtime:,
        wait_timeout: agent_class.subagent_long_poll_duration,
        parent_session: conversation_id ? runtime.open_subagent_session(run, conversation_id) : run.session,
        cancellation_token: run.cancellation_token,
        deadline: run.invocation.deadline_at,
        parent_agent_path: agent_path,
        observer: lambda do |event|
          delegation_activity.publish
          run.publish(:subagent, event:)
        end
      ).tools
    end

    def declared_agent(
      declaration,
      run,
      conversation_id: nil,
      agent_path: Subagents::AgentPath::ROOT,
      agent_stream_path: []
    )
      reference = declaration.fetch(:agent)
      agent_class = if reference.is_a?(AssemblyDefinition)
        reference.implementation
      else
        @resolve_agent.call(reference)
      end
      build_agent(
        agent_class, run:,
        model: resolve(declaration[:model], run),
        tools: Array(resolve(declaration[:tools], run)),
        conversation_id:,
        agent_path:,
        agent_stream_path:
      )
    end

    def stream_bound_definition(definition, agent_stream_path)
      factory = definition.factory
      Subagents::Definition.new(
        kind: definition.kind,
        description: definition.description,
        persist: definition.persist,
        accepts_conversation_id: definition.accepts_conversation_id,
        factory: lambda do |*arguments, **_options|
          invoke_factory(factory, *arguments).tap do |agent|
            agent.bind_agent_stream_path(agent_stream_path) if agent.respond_to?(:bind_agent_stream_path)
          end
        end
      )
    end

    def close_tools(tools)
      Array(tools).reverse_each do |tool|
        tool.close if tool.is_a?(Tool)
      rescue
        nil
      end
    end

    def resolve(value, run)
      value.is_a?(Proc) ? value.call(run) : value
    end

    def invoke_factory(factory, *arguments)
      accepts_runtime = factory.parameters.any? do |kind, name|
        %i[key keyreq keyrest].include?(kind) && (name == :runtime || kind == :keyrest)
      end
      accepts_runtime ? factory.call(*arguments, runtime: @runtime) : factory.call(*arguments)
    end
  end
end
