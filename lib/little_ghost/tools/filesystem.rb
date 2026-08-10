# frozen_string_literal: true

module LittleGhost
  # Ready-made model-facing tools for filesystem, process, and planning work.
  # Each tool uses the same binding and sandbox rules as an application tool.
  module Tools
    # Filesystem gives an agent read, list, write, and replace tools backed by the
    # application's Sandbox. A read-only sandbox automatically exposes only the
    # non-mutating tools.
    #
    #   binding = LittleGhost::Tool::Binding.new(sandbox: sandbox)
    #   registry = LittleGhost::ToolRegistry.new(
    #     [LittleGhost::Tools::Filesystem], binding: binding
    #   )
    #   registry.names # => ["read_file", "list_files"]
    #
    # === Security and trust
    #
    # These tools do not add isolation. The configured sandbox must enforce path
    # containment, permissions, size limits, and cancellation.
    class Filesystem
      # Reads one UTF-8 text file through the configured sandbox.
      class ReadFile < Tool
        tool_name "read_file"
        description "Read a UTF-8 text file within the configured workspace."
        input_schema type: "object", properties: {path: {type: "string"}}, required: ["path"], additionalProperties: false

        # Returns the UTF-8 text at <tt>input["path"]</tt> through the sandbox.
        def call(input)
          sandbox.read(input.fetch("path"), context:)
        end
      end

      # Lists one directory through the configured sandbox.
      class ListFiles < Tool
        tool_name "list_files"
        description "List files and directories within the configured workspace."
        input_schema type: "object", properties: {path: {type: "string"}}, additionalProperties: false

        # Returns the listing for <tt>input["path"]</tt>, or the workspace root
        # when +path+ is omitted.
        def call(input)
          sandbox.list(input.fetch("path", "."), context:)
        end
      end

      # Writes one UTF-8 text file through a writable sandbox.
      class WriteFile < Tool
        tool_name "write_file"
        description "Write a UTF-8 text file within the configured writable workspace."
        input_schema type: "object", properties: {
          path: {type: "string"}, content: {type: "string"}
        }, required: %w[path content], additionalProperties: false

        # Writes <tt>input["content"]</tt> to <tt>input["path"]</tt> through the
        # sandbox.
        def call(input)
          sandbox.write(input.fetch("path"), input.fetch("content"), context:)
        end
      end

      # Replaces one unique text occurrence through a writable sandbox.
      class ReplaceInFile < Tool
        tool_name "replace_in_file"
        description "Replace one unique occurrence of text in a UTF-8 file within a configured writable workspace."
        input_schema type: "object", properties: {
          path: {type: "string"}, old_text: {type: "string"}, new_text: {type: "string"}
        }, required: %w[path old_text new_text], additionalProperties: false

        # Replaces the one matching +old_text+ occurrence at +path+.
        def call(input)
          sandbox.replace(input.fetch("path"), input.fetch("old_text"), input.fetch("new_text"), context:)
        end
      end

      class ExclusiveReadFile < ReadFile # :nodoc:
        exclusive true
      end

      class ExclusiveListFiles < ListFiles # :nodoc:
        exclusive true
      end

      class ExclusiveWriteFile < WriteFile # :nodoc:
        exclusive true
      end

      class ExclusiveReplaceInFile < ReplaceInFile # :nodoc:
        exclusive true
      end

      # Selects the tool classes allowed by +binding.sandbox+.
      class << self
        # Provides read tools for every sandbox and mutation tools only when the
        # sandbox is writable.
        def tools(binding)
          [*read_tools, *(write_tools if binding.sandbox.writable?)]
        end

        private

        def read_tools = [ReadFile, ListFiles]
        def write_tools = [WriteFile, ReplaceInFile]
      end

      # Provides filesystem tools marked exclusive for shared workspace mutation.
      # Read operations are also serialized so a batch cannot observe a concurrent
      # write from another tool call in the same run.
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
