# frozen_string_literal: true

module LittleGhost
  module Tools
    class Filesystem
      class ReadFile < Tool
        tool_name "read_file"
        description "Read a UTF-8 text file within the configured workspace."
        input_schema type: "object", properties: {path: {type: "string"}}, required: ["path"], additionalProperties: false

        def call(input)
          sandbox.read(input.fetch("path"), context:)
        end
      end

      class ListFiles < Tool
        tool_name "list_files"
        description "List files and directories within the configured workspace."
        input_schema type: "object", properties: {path: {type: "string"}}, additionalProperties: false

        def call(input)
          sandbox.list(input.fetch("path", "."), context:)
        end
      end

      class WriteFile < Tool
        tool_name "write_file"
        description "Write a UTF-8 text file within the configured writable workspace."
        input_schema type: "object", properties: {
          path: {type: "string"}, content: {type: "string"}
        }, required: %w[path content], additionalProperties: false

        def call(input)
          sandbox.write(input.fetch("path"), input.fetch("content"), context:)
        end
      end

      class ReplaceInFile < Tool
        tool_name "replace_in_file"
        description "Replace one unique occurrence of text in a UTF-8 file within a configured writable workspace."
        input_schema type: "object", properties: {
          path: {type: "string"}, old_text: {type: "string"}, new_text: {type: "string"}
        }, required: %w[path old_text new_text], additionalProperties: false

        def call(input)
          sandbox.replace(input.fetch("path"), input.fetch("old_text"), input.fetch("new_text"), context:)
        end
      end

      class ExclusiveReadFile < ReadFile
        exclusive true
      end

      class ExclusiveListFiles < ListFiles
        exclusive true
      end

      class ExclusiveWriteFile < WriteFile
        exclusive true
      end

      class ExclusiveReplaceInFile < ReplaceInFile
        exclusive true
      end

      class << self
        def tools(binding)
          [*read_tools, *(write_tools if binding.sandbox.writable?)]
        end

        private

        def read_tools = [ReadFile, ListFiles]
        def write_tools = [WriteFile, ReplaceInFile]
      end

      class Exclusive < self
        class << self
          private

          def read_tools = [ExclusiveReadFile, ExclusiveListFiles]
          def write_tools = [ExclusiveWriteFile, ExclusiveReplaceInFile]
        end
      end
    end
  end
end
