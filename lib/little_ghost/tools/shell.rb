# frozen_string_literal: true

require "json"

module LittleGhost
  module Tools
    class Shell < Tool
      DEFAULT_TIMEOUT = 30
      MAX_OUTPUT_BYTES = 1_000_000

      tool_name "shell"
      description "Run one executable with arguments in the configured workspace. Shell syntax is not interpreted."
      input_schema type: "object", properties: {
        command: {type: "array", items: {type: "string"}}
      }, required: ["command"], additionalProperties: false

      def call(input)
        result = sandbox.execute_program(
          input.fetch("command"),
          timeout: DEFAULT_TIMEOUT,
          context:,
          max_output_bytes: MAX_OUTPUT_BYTES,
          environment: {},
          inherit_environment: false
        )
        JSON.generate(
          stdout: result.stdout,
          stderr: result.stderr,
          exit_status: result.exit_code,
          success: result.success?
        )
      end
    end
  end
end
