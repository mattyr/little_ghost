# frozen_string_literal: true

module LittleGhost
  class AgentBuilder
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

    def initialize(application:, primary_agent:, prompt_paths:, resolve_agent:)
      @application = application
      @primary_agent = primary_agent
      @prompt_paths = prompt_paths
      @resolve_agent = resolve_agent
    end

    def build(
      agent_class_or_name = @primary_agent,
      run:,
      model: nil,
      tools: [],
      conversation_id: nil,
      agent_path: Subagents::AgentPath::ROOT
    )
      agent_class = @resolve_agent.call(agent_class_or_name)
      build_agent(agent_class, run:, model:, tools:, conversation_id:, agent_path:)
    end

    private

    attr_reader :application, :prompt_paths

    def instantiate(agent_class, run:, tools:, model:, delegation_activity:, agent_path:)
      agent_class.new(
        model:,
        tools:,
        instrumentation: application.instrumentation,
        template_paths: prompt_paths,
        run:,
        delegation_activity:,
        agent_path:,
        **agent_class.limits
      )
    end

    def build_agent(
      agent_class,
      run:,
      model:,
      tools:,
      conversation_id: nil,
      agent_path: Subagents::AgentPath::ROOT
    )
      delegation_activity = ActivityRelay.new
      configured_tools = Array(tools).dup
      configured_tools.concat(
        delegation_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:)
      )
      resolved_model = model || application.model_for(agent_class, run)
      transferred = true
      instantiate(
        agent_class,
        run:,
        model: resolved_model,
        tools: configured_tools,
        delegation_activity:,
        agent_path:
      )
    rescue
      close_tools(configured_tools) unless transferred
      raise
    end

    def delegation_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:)
      tools = agent_tools(agent_class, run)
      tools.concat(subagent_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:))
    rescue
      close_tools(tools)
      raise
    end

    def agent_tools(agent_class, run)
      tools = []
      agent_class.agent_tool_declarations.each do |declaration|
        child = declared_agent(declaration, run)
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

    def subagent_tools(agent_class, run, conversation_id:, delegation_activity:, agent_path:)
      definitions = agent_class.subagent_declarations.map do |declaration|
        Subagents::Definition.new(
          kind: declaration.fetch(:kind),
          description: declaration.fetch(:description),
          persist: declaration.fetch(:persist, true),
          accepts_conversation_id: true,
          factory: lambda do |subagent_id, child_conversation_id = nil|
            factory = declaration[:factory]
            if factory
              factory.call(subagent_id, run)
            else
              declared_agent(
                declaration,
                run,
                conversation_id: child_conversation_id,
                agent_path: subagent_id
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
        definitions.concat(resolved.reject { |definition| declared_kinds.include?(definition.kind) })
      end
      return [] if definitions.empty?

      Subagents::Manager.new(
        definitions,
        wait_timeout: agent_class.subagent_long_poll_duration,
        parent_session: conversation_id ? application.open_subagent_session(run, conversation_id) : run.session,
        cancellation_token: run.cancellation_token,
        deadline: run.invocation.deadline_at,
        parent_agent_path: agent_path,
        observer: lambda do |event|
          delegation_activity.publish
          run.publish(:subagent, event:)
        end
      ).tools
    end

    def declared_agent(declaration, run, conversation_id: nil, agent_path: Subagents::AgentPath::ROOT)
      agent_class = @resolve_agent.call(declaration.fetch(:agent))
      build_agent(
        agent_class, run:,
        model: resolve(declaration[:model], run),
        tools: Array(resolve(declaration[:tools], run)),
        conversation_id:,
        agent_path:
      )
    end

    def close_tools(tools)
      Array(tools).reverse_each do |tool|
        tool.close if tool.is_a?(Tool) && tool.respond_to?(:close)
      rescue
        nil
      end
    end

    def resolve(value, run)
      value.is_a?(Proc) ? value.call(run) : value
    end
  end
end
