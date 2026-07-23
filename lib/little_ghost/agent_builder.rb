# frozen_string_literal: true

module LittleGhost
  class AgentBuilder
    def initialize(application:, primary_agent:, prompt_paths:, resolve_agent:)
      @application = application
      @primary_agent = primary_agent
      @prompt_paths = prompt_paths
      @resolve_agent = resolve_agent
    end

    def build(agent_class_or_name = @primary_agent, run:, model: nil, tools: [])
      agent_class = @resolve_agent.call(agent_class_or_name)
      build_agent(agent_class, run:, model:, tools:)
    end

    private

    attr_reader :application, :prompt_paths

    def instantiate(agent_class, run:, tools:, model:)
      agent_class.new(
        model:,
        tools:,
        instrumentation: application.instrumentation,
        template_paths: prompt_paths,
        run:,
        **agent_class.limits
      )
    end

    def build_agent(agent_class, run:, model:, tools:)
      configured_tools = Array(tools)
      configured_tools.concat(delegation_tools(agent_class, run))
      resolved_model = model || application.model_for(agent_class, run)
      transferred = true
      instantiate(agent_class, run:, model: resolved_model, tools: configured_tools)
    rescue
      close_tools(configured_tools) unless transferred
      raise
    end

    def delegation_tools(agent_class, run)
      tools = agent_tools(agent_class, run)
      tools.concat(subagent_tools(agent_class, run))
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

    def subagent_tools(agent_class, run)
      definitions = agent_class.subagent_declarations.map do |declaration|
        Subagents::Definition.new(
          kind: declaration.fetch(:kind),
          description: declaration.fetch(:description),
          factory: lambda do |subagent_id|
            factory = declaration[:factory]
            factory ? factory.call(subagent_id, run) : declared_agent(declaration, run)
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
        cancellation_token: run.cancellation_token,
        deadline: run.invocation.deadline_at,
        observer: ->(event) { run.publish(:subagent, event:) }
      ).tools
    end

    def declared_agent(declaration, run)
      agent_class = @resolve_agent.call(declaration.fetch(:agent))
      build_agent(
        agent_class, run:,
        model: resolve(declaration[:model], run),
        tools: Array(resolve(declaration[:tools], run))
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
