# frozen_string_literal: true

module LittleGhost
  module Tools
    class Filesystem
      def initialize(workspace:)
        @workspace = workspace
      end

      def tools
        available = [read_tool, list_tool]
        available.concat([write_tool, replace_tool]) if writable?
        available
      end

      private

      attr_reader :workspace

      def writable? = workspace.writable?

      def read_tool
        workspace = self.workspace
        Tool.define(
          name: "read_file",
          description: "Read a UTF-8 text file within the configured workspace.",
          input_schema: path_schema
        ) { |input| workspace.read(input.fetch("path")) }
      end

      def list_tool
        workspace = self.workspace
        Tool.define(
          name: "list_files",
          description: "List files and directories within the configured workspace.",
          input_schema: path_schema(required: false)
        ) { |input| workspace.list(input.fetch("path", ".")) }
      end

      def write_tool
        workspace = self.workspace
        Tool.define(
          name: "write_file",
          description: "Write a UTF-8 text file within the configured writable workspace.",
          input_schema: {
            type: "object",
            properties: {path: {type: "string"}, content: {type: "string"}},
            required: %w[path content],
            additionalProperties: false
          }
        ) { |input| workspace.write(input.fetch("path"), input.fetch("content")) }
      end

      def replace_tool
        workspace = self.workspace
        Tool.define(
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
        ) do |input|
          workspace.replace(input.fetch("path"), input.fetch("old_text"), input.fetch("new_text"))
        end
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
