# frozen_string_literal: true

module LittleGhost
  class Agent
    # Let an agent discover application-authored instructions only when it needs them.
    # Skills are file-backed guides advertised in the system prompt and loaded
    # through a model-callable catalog tool.
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     skills paths: [File.expand_path("../skills", __dir__)]
    #   end
    #
    # A run with a +refunds+ skill sees that skill in its discovery prompt. The
    # model can then call the +skills+ tool to read the full guide before handling
    # the refund request.
    #
    # Including this module alone has no effect. The +skills+ declaration installs
    # the catalog tool and prompt callback; paths may be static or resolved for
    # each run, and omitted paths use the runtime's configured skill roots. An
    # empty catalog exposes neither a tool nor discovery text.
    #
    # Skill files influence model behavior and should come from application-owned,
    # trusted roots. Catalog loading applies its own file, count, and size bounds.
    module Skills
      def self.included(base) # :nodoc:
        base.extend(ClassMethods)
        base.class_attribute :skills_configuration_value
      end

      class CatalogTools # :nodoc:
        def self.tools(binding)
          configuration = binding.agent.class.skills_configuration
          paths = configuration.fetch(:paths)
          if paths.is_a?(Proc)
            paths = paths.parameters.empty? ? binding.agent.instance_exec(&paths) : paths.call(binding.run)
          end
          paths ||= binding.run.runtime.skill_paths
          catalog = LittleGhost::Skills::Catalog.new(
            **configuration.merge(
              paths:,
              resource_root: binding.run&.runtime&.skill_resource_root,
              workspace: binding.workspace,
              sandbox: binding.sandbox
            )
          )
          return [] if catalog.names.empty?

          [catalog.tool.tap { |tool| tool.define_method(:catalog) { catalog } }]
        end
      end

      # Exposes skill discovery declarations on agent classes.
      # These methods become inheritable DSL entries when the capability is included.
      module ClassMethods
        # :call-seq:
        #   skills(*paths, **options) -> configuration
        #   skills(paths: paths_or_resolver, **options) -> configuration
        #
        # Enables skill discovery for this agent. +paths+ may be paths or a
        # callable resolved for each run. When omitted, the runtime's configured
        # skill paths are used.
        #
        def skills(*values, **options)
          configured_paths = if options.key?(:paths)
            options.delete(:paths)
          elsif values.empty?
            nil
          else
            values.flatten
          end
          self.skills_configuration_value = options.merge(paths: configured_paths)
          tools CatalogTools
          prompt_local(:skills_prompt) do
            tool = tools.fetch("skills") if tools.names.include?("skills")
            tool&.catalog&.discovery_prompt.to_s
          end
          before_invocation :include_skills_prompt
        end

        def skills_configuration = skills_configuration_value # :nodoc:
      end

      private

      def include_skills_prompt(payload)
        prompt = prompt_locals[:skills_prompt].to_s
        return Support::Callbacks.continue if prompt.empty?

        messages = payload.fetch(:messages).dup
        index = messages.index { |message| message.role == :system }
        return Support::Callbacks.continue unless index

        message = messages.fetch(index)
        content = message.content.dup
        content << Content::Text.new(text: "\n\n#{prompt}")
        messages[index] = Message.new(role: :system, content:, metadata: message.metadata)
        Support::Callbacks.replace(payload.merge(messages:))
      end
    end
  end
end
