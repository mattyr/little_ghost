# frozen_string_literal: true

module LittleGhost
  class Agent
    module Skills
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :skills_configuration_value
      end

      class CatalogTools
        def self.tools(binding)
          configuration = binding.agent.class.skills_configuration
          paths = configuration.fetch(:paths)
          if paths.is_a?(Proc)
            paths = paths.parameters.empty? ? binding.agent.instance_exec(&paths) : paths.call(binding.run)
          end
          paths ||= binding.run.runtime.skill_paths
          catalog = LittleGhost::Skills::Catalog.new(
            **configuration.merge(paths:, resource_root: binding.run&.runtime&.skill_resource_root)
          )
          return [] if catalog.names.empty?

          [catalog.tool.tap { |tool| tool.define_method(:catalog) { catalog } }]
        end
      end

      module ClassMethods
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

        def skills_configuration = skills_configuration_value
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
