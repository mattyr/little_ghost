# frozen_string_literal: true

module LittleGhost
  class Agent
    module Delegation
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def subagent(agent_class, kind: nil, description: nil, model: nil, tools: nil, factory: nil)
          validate_delegated_tools!(tools)
          declaration = Support.immutable({
            agent: agent_class,
            kind: (kind || agent_class.agent_id).to_s,
            description: description || agent_class.description,
            model:,
            tools:,
            factory:
          })
          @subagent_declarations = [*subagent_declarations, declaration].freeze
        end

        def subagents(*agent_classes, **options, &resolver)
          agent_classes.each { |agent_class| subagent(agent_class, **options) }
          @subagent_resolvers = [*subagent_resolvers, resolver].freeze if resolver
          subagent_declarations
        end

        def subagent_declarations
          return @subagent_declarations if instance_variable_defined?(:@subagent_declarations)

          superclass.respond_to?(:subagent_declarations) ? superclass.subagent_declarations : [].freeze
        end

        def subagent_resolvers
          return @subagent_resolvers if instance_variable_defined?(:@subagent_resolvers)

          superclass.respond_to?(:subagent_resolvers) ? superclass.subagent_resolvers : [].freeze
        end

        def agent_as_tool(agent_class, name: nil, description: nil, model: nil, tools: nil,
          preserve_context: false)
          validate_delegated_tools!(tools)
          declaration = Support.immutable({
            agent: agent_class,
            name: (name || agent_class.agent_id).to_s,
            description: description || agent_class.description,
            model:,
            tools:,
            preserve_context:
          })
          @agent_tool_declarations = [*agent_tool_declarations, declaration].freeze
        end

        def agents_as_tools(*agent_classes, **options)
          agent_classes.each { |agent_class| agent_as_tool(agent_class, **options) }
          agent_tool_declarations
        end

        def agent_tool_declarations
          return @agent_tool_declarations if instance_variable_defined?(:@agent_tool_declarations)

          superclass.respond_to?(:agent_tool_declarations) ? superclass.agent_tool_declarations : [].freeze
        end

        private

        def validate_delegated_tools!(tools)
          return unless Array(tools).flatten.any? { |tool| tool.is_a?(Tool) }

          raise ConfigurationError,
            "Delegated tools must be tool classes or a resolver that creates fresh instances"
        end
      end
    end
  end
end
