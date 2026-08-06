# frozen_string_literal: true

require "open3"

module LittleGhost
  class Sandbox
    Execution = Data.define(:stdout, :stderr, :exit_code) do
      def success?
        exit_code.zero?
      end
    end

    def initialize(workspace:)
      @workspace = workspace
    end

    attr_reader :workspace

    def execute(command, timeout:, context: nil, max_output_bytes: 1_000_000)
      execute_program(
        ["/bin/sh", "-c", String(command)],
        timeout:,
        context:,
        max_output_bytes:
      )
    end

    def execute_program(
      command,
      timeout:,
      context: nil,
      max_output_bytes: 1_000_000,
      environment: {},
      inherit_environment: false
    )
      argv = Array(command).map(&:to_s)
      raise ToolError, "Command must contain an executable" if argv.empty? || argv.first.empty?

      timeout = Float(timeout)
      max_output_bytes = Integer(max_output_bytes)
      raise ArgumentError, "timeout must be positive" unless timeout.positive?
      raise ArgumentError, "max_output_bytes must be positive" unless max_output_bytes.positive?

      stdout, stderr, status = capture(
        argv,
        timeout:,
        context:,
        max_output_bytes:,
        environment:,
        inherit_environment:
      )
      Execution.new(stdout:, stderr:, exit_code: status.exitstatus)
    end

    def close
      workspace.close
    end

    private

    def capture(argv, timeout:, context:, max_output_bytes:, environment:, inherit_environment:)
      result = nil
      deadline = monotonic_time + timeout
      Open3.popen3(
        environment.transform_keys(&:to_s).transform_values(&:to_s),
        *argv,
        chdir: workspace.root,
        pgroup: true,
        unsetenv_others: !inherit_environment
      ) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { drain(stdout, max_output_bytes) }
        stderr_reader = Thread.new { drain(stderr, max_output_bytes) }
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
        raise ToolError, "Command timed out" if monotonic_time >= deadline

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

    def drain(io, max_output_bytes)
      captured = +""
      while (chunk = io.read(16_384))
        remaining = max_output_bytes + 1 - captured.bytesize
        captured << chunk.byteslice(0, remaining) if remaining.positive?
      end
      truncate(captured, max_output_bytes)
    end

    def truncate(output, max_output_bytes)
      return output if output.bytesize <= max_output_bytes

      "#{output.byteslice(0, max_output_bytes)}\n[output truncated]"
    end
  end
end
