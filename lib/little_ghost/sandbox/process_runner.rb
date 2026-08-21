# frozen_string_literal: true

require "open3"

module LittleGhost
  class Sandbox
    # Runs one bounded child process and terminates its entire process group when
    # the Run is cancelled or the command exceeds its timeout.
    class ProcessRunner # :nodoc:
      POLL_INTERVAL = 0.01
      TERMINATION_GRACE = 0.5

      def self.run(...) = new(...).run

      def initialize(command:, timeout:, context: nil, max_output_bytes: 1_000_000,
        environment: {}, inherit_environment: false, chdir: nil)
        @command = Array(command).map(&:to_s)
        @timeout = Float(timeout)
        @context = context
        @max_output_bytes = Integer(max_output_bytes)
        @environment = environment.transform_keys(&:to_s).transform_values(&:to_s)
        @inherit_environment = inherit_environment
        @chdir = chdir

        raise ToolError, "Command must contain an executable" if @command.empty? || @command.first.empty?
        raise ArgumentError, "timeout must be positive" unless @timeout.positive? && @timeout.finite?
        raise ArgumentError, "max_output_bytes must be positive" unless @max_output_bytes.positive?
      end

      def run
        result = nil
        options = {pgroup: true, unsetenv_others: !@inherit_environment}
        options[:chdir] = @chdir if @chdir
        Open3.popen3(@environment, *@command, **options) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { drain(stdout) }
          stderr_reader = Thread.new { drain(stderr) }
          wait_for(wait_thread, [stdout_reader, stderr_reader])
          result = Execution.new(
            stdout: stdout_reader.value,
            stderr: stderr_reader.value,
            exit_code: wait_thread.value.exitstatus
          )
        ensure
          stdout_reader&.kill
          stderr_reader&.kill
        end
        result
      rescue Errno::ENOENT
        Execution.new(stdout: "", stderr: "#{@command.first}: command not found\n", exit_code: 127)
      end

      private

      def wait_for(wait_thread, readers)
        deadline = monotonic_time + @timeout
        until !wait_thread.alive? && readers.none?(&:alive?)
          @context&.check!
          raise ToolError, "Command timed out after #{@timeout} seconds" if monotonic_time >= deadline

          wait_thread.join(POLL_INTERVAL)
        end
      rescue
        terminate(wait_thread.pid)
        raise
      end

      def terminate(pid)
        Process.kill("TERM", -pid)
        deadline = monotonic_time + TERMINATION_GRACE
        sleep(POLL_INTERVAL) while monotonic_time < deadline && process_group_alive?(pid)
        Process.kill("KILL", -pid) if process_group_alive?(pid)
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

      def drain(io)
        captured = String.new(encoding: Encoding::BINARY)
        truncated = false
        while (chunk = io.read(16_384))
          remaining = @max_output_bytes - captured.bytesize
          captured << chunk.byteslice(0, remaining) if remaining.positive?
          truncated ||= chunk.bytesize > remaining
        end
        captured = captured.force_encoding(Encoding::UTF_8).scrub
        truncated ? "#{captured}\n[output truncated]" : captured
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
