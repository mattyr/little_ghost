# frozen_string_literal: true

module LittleGhost
  class Agent
    # Give one agent a bounded way to ask another agent for help.
    # Delegated agents can run as managed subagents or behind an ordinary tool call.
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     subagent ResearchAgent, kind: "research"
    #     agent_as_tool SentimentAgent, name: "classify_sentiment"
    #   end
    #
    # The support model receives spawn, messaging, interjection, waiting, and
    # listing tools for the +research+ kind. It sees the sentiment agent as one
    # regular tool whose result is returned to the current turn.
    #
    # Static declarations may be combined with a resolver that returns dynamic
    # Subagents::Definition objects. Managed conversations persist when a session
    # store is configured unless <tt>persist: false</tt> keeps them local to one
    # invocation. An agent exposed as a tool starts with empty history unless
    # <tt>preserve_context: true</tt> serializes calls and retains its history.
    #
    # Tool overrides must be classes. A delegated agent otherwise receives only
    # its own declared tools; it does not inherit the parent's registry. The
    # manager enforces its concurrency, identity, polling, and persistence bounds.
    module Delegation
      def self.included(base) # :nodoc:
        base.extend(ClassMethods)
        base.class_attribute :subagent_long_poll_duration_value,
          default: Subagents::Manager::DEFAULT_WAIT_TIMEOUT
        base.class_attribute :subagent_declarations_value, default: []
        base.class_attribute :subagent_resolvers_value, default: []
        base.class_attribute :assembly_tool_declarations_value, default: []
      end

      # Exposes delegation declarations on agent classes.
      # These methods become inheritable DSL entries when the capability is included.
      module ClassMethods
        # :call-seq:
        #   subagent_long_poll_duration() -> Float
        #   subagent_long_poll_duration(seconds) -> Float
        #
        # The maximum long-poll duration used by subagent wait tools.
        #
        # The default comes from Subagents::Manager. Values must be positive,
        # finite numbers and are normalized to Float.
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

        # Adds +agent_class+ as an available managed subagent.
        #
        # +kind+ defaults to the agent ID and +description+ defaults to the
        # agent description. Conversations persist when a session store exists;
        # pass <tt>persist: false</tt> for invocation-local work.
        #
        #   subagent ResearchAgent, kind: "research"
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

        # Adds several static subagents and an optional dynamic definition resolver.
        def subagents(*agent_classes, **options, &resolver)
          agent_classes.each { |agent_class| subagent(agent_class, **options) }
          self.subagent_resolvers_value = [*subagent_resolvers, resolver] if resolver
          subagent_declarations
        end

        def subagent_declarations = subagent_declarations_value # :nodoc:

        def subagent_resolvers = subagent_resolvers_value # :nodoc:

        # Exposes +agent_class+ as one ordinary tool.
        #
        # Pass <tt>preserve_context: true</tt> to retain the delegated agent's
        # conversational history between calls to that tool instance.
        def agent_as_tool(agent_class, name: nil, description: nil, model: nil, tools: nil,
          preserve_context: false)
          assembly_as_tool(
            agent_class,
            name:,
            description:,
            model:,
            tools:,
            preserve_context:
          )
        end

        # Exposes an Agent, Workflow, Swarm, or Graph as one ordinary tool.
        # Agent-only +model+ and +tools+ overrides are rejected for composites.
        def assembly_as_tool(assembly_class, name: nil, description: nil, model: nil, tools: nil,
          preserve_context: false)
          unless assembly_class.is_a?(Class) && assembly_class <= Assembly
            raise ConfigurationError, "Delegated assemblies must inherit from LittleGhost::Assembly"
          end
          validate_delegated_tools!(tools)
          if !(assembly_class <= Agent) && (model || tools)
            raise ConfigurationError, "Composite assemblies do not accept delegated model or tool overrides"
          end
          declaration = {
            assembly: assembly_class,
            name: (name || assembly_class.assembly_id).to_s,
            description: description || assembly_class.description,
            model:,
            tools:,
            preserve_context:
          }
          self.assembly_tool_declarations_value = [*assembly_tool_declarations, declaration]
        end

        # Exposes several agent classes as ordinary tools with shared options.
        def agents_as_tools(*agent_classes, **options)
          agent_classes.each { |agent_class| agent_as_tool(agent_class, **options) }
          assembly_tool_declarations
        end

        # Exposes several assembly classes as ordinary tools with shared options.
        def assemblies_as_tools(*assembly_classes, **options)
          assembly_classes.each { |assembly_class| assembly_as_tool(assembly_class, **options) }
          assembly_tool_declarations
        end

        def assembly_tool_declarations = assembly_tool_declarations_value # :nodoc:
        def agent_tool_declarations = assembly_tool_declarations # :nodoc:

        private

        def validate_delegated_tools!(tools)
          return unless Array(tools).flatten.any? { |tool| !tool.is_a?(Class) }

          raise ConfigurationError, "Delegated tools must be classes"
        end
      end
    end
  end
end
