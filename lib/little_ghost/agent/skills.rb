# frozen_string_literal: true

module LittleGhost
  class Agent
    module Skills
      def self.included(base)
        base.extend(ClassMethods)
        base.class_attribute :skills_configuration_value
        base.class_attribute :skills_tool_resolver_value
      end

      module ClassMethods
        def skills(*values, **options)
          configured_paths = options.key?(:paths) ? options.delete(:paths) : values.flatten
          self.skills_configuration_value = options.merge(paths: configured_paths)
          resolver = lambda do
            configuration = self.class.skills_configuration
            paths = configuration.fetch(:paths)
            if paths.is_a?(Proc)
              paths = paths.parameters.empty? ? instance_exec(&paths) : paths.call(run)
            end
            catalog = LittleGhost::Skills::Catalog.new(**configuration.merge(paths: Array(paths)))
            next [] if catalog.names.empty?

            catalog.tool.tap { |tool| tool.define_method(:catalog) { catalog } }
          end
          self.skills_tool_resolver_value = resolver
          tools(&resolver)
          prompt_local(:skills_prompt) do
            tool = tools.fetch("skills") if tools.names.include?("skills")
            tool&.catalog&.discovery_prompt.to_s
          end
          before_invocation :include_skills_prompt
        end

        def skills_configuration = skills_configuration_value

        private

        def skills_tool_resolver = skills_tool_resolver_value
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
