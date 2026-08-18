# frozen_string_literal: true

require "json"

module LittleGhost
  module Tools
    # Shell lets an agent run one executable through the configured Sandbox. It
    # accepts an argument vector, so model-supplied values are not interpreted as
    # shell syntax.
    #
    # The child environment is cleared, runtime is limited to 30 seconds, and
    # each output stream is limited to 1 MB. Commands may spawn children when
    # the backend supports them. These defaults reduce accidental exposure but
    # do not create an isolation boundary; the configured sandbox remains
    # responsible for security.
    class Shell < Tool
      DEFAULT_TIMEOUT = 30 # :nodoc:
      MAX_OUTPUT_BYTES = 1_000_000 # :nodoc:

      tool_name "shell"
      description "Run one executable with arguments in the configured workspace. Shell syntax is not interpreted."
      input_schema type: "object", properties: {
        command: {type: "array", items: {type: "string"}}
      }, required: ["command"], additionalProperties: false

      # Executes <tt>input["command"]</tt> and returns a JSON result containing
      # standard output, standard error, exit status, and success.
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
