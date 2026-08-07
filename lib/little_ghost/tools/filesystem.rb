# frozen_string_literal: true

module LittleGhost
  module Tools
    class Filesystem
      def initialize(sandbox:, exclusive: false)
        @sandbox = sandbox
        @exclusive = exclusive
      end

      def tools
        available = [read_tool, list_tool]
        available.concat([write_tool, replace_tool]) if writable?
        available
      end

      private

      attr_reader :sandbox

      def writable? = sandbox.writable?

      def read_tool
        sandbox = self.sandbox
        define_tool(
          name: "read_file",
          description: "Read a UTF-8 text file within the configured workspace.",
          input_schema: path_schema
        ) { |input, context:| sandbox.read(input.fetch("path"), context:) }
      end

      def list_tool
        sandbox = self.sandbox
        define_tool(
          name: "list_files",
          description: "List files and directories within the configured workspace.",
          input_schema: path_schema(required: false)
        ) { |input, context:| sandbox.list(input.fetch("path", "."), context:) }
      end

      def write_tool
        sandbox = self.sandbox
        define_tool(
          name: "write_file",
          description: "Write a UTF-8 text file within the configured writable workspace.",
          input_schema: {
            type: "object",
            properties: {path: {type: "string"}, content: {type: "string"}},
            required: %w[path content],
            additionalProperties: false
          }
        ) { |input, context:| sandbox.write(input.fetch("path"), input.fetch("content"), context:) }
      end

      def replace_tool
        sandbox = self.sandbox
        define_tool(
          name: "replace_in_file",
          description: "Replace one unique occurrence of text in a UTF-8 file within a configured writable workspace.",
          input_schema: {
            type: "object",
            properties: {
              path: {type: "string"}, old_text: {type: "string"}, new_text: {type: "string"}
            },
            required: %w[path old_text new_text],
            additionalProperties: false
          }
        ) do |input, context:|
          sandbox.replace(
            input.fetch("path"),
            input.fetch("old_text"),
            input.fetch("new_text"),
            context:
          )
        end
      end

      def define_tool(**options, &implementation)
        Tool.define(**options, &implementation).tap { |tool| tool.exclusive(@exclusive) }
      end

      def path_schema(required: true)
        {
          type: "object",
          properties: {path: {type: "string"}},
          required: required ? ["path"] : [],
          additionalProperties: false
        }
      end
    end
  end
end
