# frozen_string_literal: true

require "open3"

module LittleGhost
  # Built-in sandbox provider classes grouped for direct construction.
  module Sandboxes
    # A convenient host-backed sandbox for trusted local work. It offers bounded
    # text-file operations and command execution using only Ruby's standard
    # library.
    #
    #   workspace = LittleGhost::Workspace.new(root: Dir.pwd)
    #   sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)
    #   sandbox.read("README.md").lines.first # => "# LittleGhost\n"
    #
    # Reads return valid UTF-8 text. Writes preserve the supplied String bytes.
    # Paths may be relative to the workspace or absolute within a declared
    # virtual mount. Traversal components are rejected, and every path is
    # checked against its configured mount root.
    #
    # === Security and trust
    #
    # This sandbox is not a security boundary. Commands run directly on the host
    # with the Ruby process's permissions, and filesystem containment cannot defend
    # against concurrent adversarial mutation. Use an isolated Sandbox
    # implementation for untrusted work.
    class Unrestricted < Sandbox
      # Configures a host sandbox with an explicit policy and resource limits.
      def initialize(workspace:, policy: nil, profiles: {}, limits: {})
        configured_policy = policy || Sandbox::Policy.new(files: {root: :read_only}, root_filesystem: :read_write, network: :inherit)
        super(workspace:, policy: configured_policy, profiles:, limits:)
        policy = self.policy
        unless policy.network.nil? || policy.network.inherit?
          raise CapabilityError, "the unrestricted sandbox cannot enforce network mode :#{policy.network.mode}"
        end
        @effective_policy = Sandbox::Policy.new(
          files: policy.files,
          runtime_paths: policy.runtime_paths,
          root_filesystem: :read_write,
          environment: policy.environment,
          network: :inherit
        )
        @writable = effective_policy.process_grants(workspace).any?(&:writable?)
        @root = File.expand_path(workspace.root)
        capture_root_identity if File.exist?(@root)
      end

      # Opens the sandbox and verifies that the workspace root has not changed.
      def open(run: nil)
        if @root_identity
          validate_root!
        else
          @root = File.realpath(workspace.root)
          capture_root_identity
        end
        self
      end

      # Indicates whether this sandbox accepts filesystem mutations.
      def writable? = @writable

      # Reports the host permissions this backend actually uses. In particular,
      # unrestricted execution cannot make the host root filesystem read-only.
      attr_reader :effective_policy

      # Reports host execution and the bounded filesystem operations exposed by
      # this instance. +isolation: :none+ is deliberate: unrestricted execution
      # is not a security boundary.
      def capabilities
        features = %i[filesystem_read filesystem_list process_execute process_spawn]
        features.concat(%i[filesystem_write filesystem_replace]) if writable?
        Sandbox::Capabilities.new(features:, network_modes: [:inherit], isolation: :none)
      end

      # Reads a bounded UTF-8 file within the workspace.
      def read(path, context: nil) = default_scope.read(path, context:)

      # Produces a newline-delimited, sorted directory listing. Directories end in
      # +/+.
      def list(path = ".", context: nil) = default_scope.list(path, context:)

      # Writes a bounded String without following a symbolic-link target.
      def write(path, content, context: nil) = default_scope.write(path, content, context:)

      # Replaces exactly one occurrence of +old_text+ in a writable file.
      def replace(path, old_text, new_text, context: nil) = default_scope.replace(path, old_text, new_text, context:)

      # Executes an argument vector on the host from the workspace root.
      #
      # Shell syntax is not interpreted. The child starts with an empty environment
      # unless +inherit_environment+ is true, is terminated when the context is
      # cancelled or the timeout expires, and has each output stream truncated to
      # +max_output_bytes+.
      def execute_program(
        command,
        timeout:,
        context: nil,
        max_output_bytes: nil,
        environment: {},
        inherit_environment: false,
        scope: nil
      )
        argv = Array(command).map(&:to_s)
        raise ToolError, "Command must contain an executable" if argv.empty? || argv.first.empty?

        timeout = Float(timeout)
        max_output_bytes = Integer(max_output_bytes || limits.output_bytes)
        raise ArgumentError, "timeout must be positive" unless timeout.positive?
        raise ArgumentError, "max_output_bytes must be positive" unless max_output_bytes.positive?

        stdout, stderr, status = capture(
          argv,
          timeout:,
          context:,
          max_output_bytes:,
          environment: workspace.environment.merge(effective_policy.environment.values).merge(environment),
          inherit_environment: effective_policy.environment.inherit? && inherit_environment
        )
        Sandbox::Execution.new(stdout:, stderr:, exit_code: status.exitstatus)
      end

      # Starts a bounded host process. This remains unrestricted host execution,
      # not a containment boundary.
      def start_program(command, context: nil, environment: {}, inherit_environment: false,
        scope: nil, cwd: nil, output_bytes: nil, memory_bytes: nil, cpu_seconds: nil, file_bytes: nil, processes: nil,
        allow_subprocesses: true)
        Sandbox::ProcessSession.new(
          command:,
          environment: workspace.environment.merge(effective_policy.environment.values).merge(environment),
          inherit_environment: effective_policy.environment.inherit? && inherit_environment,
          chdir: cwd ? workspace.resolve(cwd) : workspace.root,
          output_bytes: output_bytes || limits.output_bytes,
          memory_bytes:,
          cpu_seconds:,
          file_bytes:,
          processes:
        )
      end

      private

      def default_scope
        @default_scope ||= scope
      end

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

      def validate_root!
        identity = File.stat(File.realpath(@root)).then { |stat| [stat.dev, stat.ino] }
        raise ToolError, "Workspace root changed after initialization" unless identity == @root_identity
      rescue Errno::ENOENT
        raise ToolError, "Workspace root changed after initialization"
      end

      def capture_root_identity
        @root = File.realpath(@root)
        @root_identity = File.stat(@root).then { |stat| [stat.dev, stat.ino] }.freeze
      end
    end
  end

  Sandbox.register_provider(:unrestricted, Sandboxes::Unrestricted)
end
