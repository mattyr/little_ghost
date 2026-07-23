# frozen_string_literal: true

require "json"
require "open3"

module LittleGhost
  module Tools
    class Shell
      def initialize(root:, timeout: 30, max_output_bytes: 1_000_000, environment: {}, inherit_environment: false)
        @root = File.realpath(root)
        @timeout = Float(timeout)
        @max_output_bytes = Integer(max_output_bytes)
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?
        raise ArgumentError, "max_output_bytes must be positive" unless @max_output_bytes.positive?

        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s).freeze
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
        ) { |input, context:| runner.run(input.fetch("command"), context: context) }
      end

      def run(command, context: nil)
        argv = Array(command).map(&:to_s)
        raise ToolError, "Command must contain an executable" if argv.empty? || argv.first.empty?

        stdout, stderr, status = capture(argv, context)
        JSON.generate(
          stdout: truncate(stdout),
          stderr: truncate(stderr),
          exit_status: status.exitstatus,
          success: status.success?
        )
      end

      private

      def capture(argv, context)
        result = nil
        deadline = monotonic_time + @timeout
        Open3.popen3(
          @environment,
          *argv,
          chdir: @root,
          pgroup: true,
          unsetenv_others: !@inherit_environment
        ) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { drain(stdout) }
          stderr_reader = Thread.new { drain(stderr) }
          wait_for(wait_thread, [stdout_reader, stderr_reader], deadline, context)
          result = [stdout_reader.value, stderr_reader.value, wait_thread.value]
        ensure
          stdout_reader&.kill
          stderr_reader&.kill
        end
        result
      end

      def wait_for(wait_thread, readers, deadline, context)
        until !wait_thread.alive? && readers.none?(&:alive?)
          context&.check!
          raise ToolError, "Command timed out after #{@timeout} seconds" if monotonic_time >= deadline

          wait_thread.join(0.01)
          Thread.pass
        end
      rescue
        terminate(wait_thread.pid)
        raise
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        deadline = monotonic_time + 0.5
        while monotonic_time < deadline
          return unless process_group_alive?(pid)

          Thread.pass
        end

        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def process_group_alive?(pid)
        Process.kill(0, -pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def truncate(output)
        return output if output.bytesize <= @max_output_bytes

        "#{output.byteslice(0, @max_output_bytes)}\n[output truncated]"
      end

      def drain(io)
        captured = +""
        while (chunk = io.read(16_384))
          remaining = (@max_output_bytes + 1) - captured.bytesize
          captured << chunk.byteslice(0, remaining) if remaining.positive?
        end
        captured
      end
    end
  end
end
