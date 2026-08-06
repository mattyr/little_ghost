# frozen_string_literal: true

require "json"

module LittleGhost
  module Tools
    class Shell
      def initialize(sandbox:, timeout: 30, max_output_bytes: 1_000_000, environment: {}, inherit_environment: false)
        @sandbox = sandbox
        @timeout = Float(timeout)
        @max_output_bytes = Integer(max_output_bytes)
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "max_output_bytes must be positive" unless @max_output_bytes.positive?

        @environment = environment
        @inherit_environment = inherit_environment
      end

      def tool
        runner = self
        Tool.define(
          name: "shell",
          description: "Run one executable with arguments in the configured workspace. Shell syntax is not interpreted.",
          input_schema: {
            type: "object",
            properties: {
              command: {type: "array", items: {type: "string"}}
            },
            required: ["command"],
            additionalProperties: false
          }
        ) { |input, context:| runner.run(input.fetch("command"), context:) }
      end

      def run(command, context: nil)
        result = sandbox.execute_program(
          command,
          timeout:,
          context:,
          max_output_bytes:,
          environment: @environment,
          inherit_environment: @inherit_environment
        )
        JSON.generate(
          stdout: result.stdout,
          stderr: result.stderr,
          exit_status: result.exit_code,
          success: result.success?
        )
      end

      private

      attr_reader :sandbox, :timeout, :max_output_bytes
    end
  end
end
