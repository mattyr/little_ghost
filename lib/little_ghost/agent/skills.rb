# frozen_string_literal: true

module LittleGhost
  class Agent
    module Skills
      PATHS_UNSET = Object.new.freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def skills(*values, paths: PATHS_UNSET, **options)
          configured_paths = paths.equal?(PATHS_UNSET) ? values.flatten : paths
          @skills_configuration = Support.immutable(options.merge(paths: configured_paths))
          @skills_tool_resolver = lambda do
            configuration = self.class.skills_configuration
            paths = configuration.fetch(:paths)
            if paths.is_a?(Proc)
              paths = paths.parameters.empty? ? instance_exec(&paths) : paths.call(run)
            end
            catalog = LittleGhost::Skills::Catalog.new(**configuration.merge(paths: Array(paths)))
            next [] if catalog.names.empty?

            catalog.tool.tap { |tool| tool.define_method(:catalog) { catalog } }
          end
          tools(&@skills_tool_resolver)
          prompt_local(:skills_prompt) do
            tool = tools.fetch("skills") if tools.names.include?("skills")
            tool&.catalog&.discovery_prompt.to_s
          end
          before_invocation :include_skills_prompt
        end

        def skills_configuration
          return @skills_configuration if instance_variable_defined?(:@skills_configuration)

          superclass.skills_configuration if superclass.respond_to?(:skills_configuration)
        end

        private

        def skills_tool_resolver
          return @skills_tool_resolver if instance_variable_defined?(:@skills_tool_resolver)

          superclass.send(:skills_tool_resolver) if superclass.respond_to?(:skills_tool_resolver, true)
        end
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
