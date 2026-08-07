# frozen_string_literal: true

module LittleGhost
  class Agent
    module Delegation
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :subagent_long_poll_duration_value,
          default: Subagents::Manager::DEFAULT_WAIT_TIMEOUT
        base.class_attribute :subagent_declarations_value, default: []
        base.class_attribute :subagent_resolvers_value, default: []
        base.class_attribute :agent_tool_declarations_value, default: []
      end

      module ClassMethods
        def subagent_long_poll_duration(*values)
          return subagent_long_poll_duration_value if values.empty?

          timeout = Float(values.fetch(0))
          unless timeout.positive? && timeout.finite?
            raise ConfigurationError, "subagent_long_poll_duration must be a positive finite number"
          end

          self.subagent_long_poll_duration_value = timeout
        rescue ArgumentError, TypeError
          raise ConfigurationError, "subagent_long_poll_duration must be a positive finite number"
        end

        def subagent(agent_class, kind: nil, description: nil, model: nil, tools: nil, factory: nil, persist: true)
          validate_delegated_tools!(tools)
          declaration = {
            agent: agent_class,
            kind: (kind || agent_class.agent_id).to_s,
            description: description || agent_class.description,
            model:,
            tools:,
            factory:,
            persist:
          }
          self.subagent_declarations_value = [*subagent_declarations, declaration]
        end

        def subagents(*agent_classes, **options, &resolver)
          agent_classes.each { |agent_class| subagent(agent_class, **options) }
          self.subagent_resolvers_value = [*subagent_resolvers, resolver] if resolver
          subagent_declarations
        end

        def subagent_declarations = subagent_declarations_value

        def subagent_resolvers = subagent_resolvers_value

        def agent_as_tool(agent_class, name: nil, description: nil, model: nil, tools: nil,
          preserve_context: false)
          validate_delegated_tools!(tools)
          declaration = {
            agent: agent_class,
            name: (name || agent_class.agent_id).to_s,
            description: description || agent_class.description,
            model:,
            tools:,
            preserve_context:
          }
          self.agent_tool_declarations_value = [*agent_tool_declarations, declaration]
        end

        def agents_as_tools(*agent_classes, **options)
          agent_classes.each { |agent_class| agent_as_tool(agent_class, **options) }
          agent_tool_declarations
        end

        def agent_tool_declarations = agent_tool_declarations_value

        private

        def validate_delegated_tools!(tools)
          return unless Array(tools).flatten.any? { |tool| !tool.is_a?(Class) }

          raise ConfigurationError, "Delegated tools must be classes"
        end
      end
    end
  end
end
