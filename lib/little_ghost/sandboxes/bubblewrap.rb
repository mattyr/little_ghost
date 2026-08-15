# frozen_string_literal: true

require_relative "../sandbox/process_runner"
require_relative "../sandbox/isolated_backend"

module LittleGhost
  module Sandboxes
    # Runs each command in a fresh Bubblewrap namespace on Linux. Bubblewrap is
    # selected explicitly and is never installed or replaced with host execution.
    # The namespace shares the outer Linux kernel and trusts the configured
    # runtime roots, mounts, command wrapper, and hosting environment. It governs
    # child processes, not arbitrary Ruby code in the parent runtime.
    class Bubblewrap < Sandbox::IsolatedBackend
      DEFAULT_EXECUTABLE = "/usr/bin/bwrap" # :nodoc:
      RUNTIME_ROOTS = %w[/usr].freeze # :nodoc:
      COMPATIBILITY_ROOTS = %w[/bin /sbin /lib /lib64].freeze # :nodoc:

      # Reports whether Bubblewrap is usable on +platform+.
      def self.probe(executable: DEFAULT_EXECUTABLE, platform: RUBY_PLATFORM)
        if !platform.include?("linux")
          {available: false, reason: "Bubblewrap is supported only on Linux", capabilities: Capabilities.new(features: [], network_modes: [])}
        elsif !File.file?(executable) || !File.executable?(executable)
          {available: false, reason: "Bubblewrap is not installed at #{executable}", capabilities: Capabilities.new(features: [], network_modes: [])}
        else
          result = Sandbox::ProcessRunner.run(
            command: [executable, "--unshare-user", "--unshare-pid", "--new-session", "--die-with-parent", "--ro-bind", "/", "/", "--", "/bin/true"],
            timeout: 5,
            max_output_bytes: 16_384
          )
          if result.success?
            {available: true, reason: nil, capabilities: backend_capabilities}
          else
            detail = result.stderr.to_s.lines.first.to_s.strip
            detail = "the namespace probe failed" if detail.empty?
            {available: false, reason: "Bubblewrap is installed but unavailable: #{detail}", capabilities: Capabilities.new(features: [], network_modes: [])}
          end
        end
      end

      # Describes the isolation and operations provided by this backend.
      def self.backend_capabilities
        Capabilities.new(
          features: %i[filesystem_read filesystem_list filesystem_write filesystem_replace process_execute virtual_filesystem],
          network_modes: %i[inherit none allowlist],
          isolation: :namespace
        )
      end

      # Builds a command-scoped Linux namespace sandbox.
      def initialize(workspace:, policy: nil, profiles: {}, limits: {}, setup: nil,
        bubblewrap: DEFAULT_EXECUTABLE, platform: RUBY_PLATFORM,
        socat: "/usr/bin/socat", gateway_options: {}, command_wrapper: nil,
        proc: :new, tmpfs: %w[/tmp /run], masks: [], runtime_roots: RUNTIME_ROOTS,
        uid: nil, gid: nil)
        if setup && (policy || !profiles.empty?)
          raise PolicyError, "deferred sandbox setup cannot be combined with policy or profiles"
        end

        super(workspace:, policy: policy || {}, profiles:, limits:)
        @bubblewrap = File.expand_path(bubblewrap)
        @platform = platform
        @socat = File.expand_path(socat)
        @gateway_options = gateway_options
        @setup = setup
        @setup_applied = !setup
        @command_wrapper = command_wrapper
        @proc = normalize_proc(proc)
        @tmpfs = Array(tmpfs).map { |path| Sandbox::Mount.send(:normalize_virtual_path, path) }.uniq.freeze
        @masks = Array(masks).map { |path| Sandbox::Mount.send(:normalize_virtual_path, path) }.uniq.freeze
        @runtime_roots = Array(runtime_roots).map { |path| File.expand_path(path) }.uniq.freeze
        @uid = normalize_identity(uid, "uid")
        @gid = normalize_identity(gid, "gid")
        @opened = false
      end

      # Returns this backend's declared capabilities.
      def capabilities = self.class.backend_capabilities

      # Validates dependencies and starts any policy gateway.
      def open(run: nil)
        return self if @opened

        apply_setup!(run:)
        raise UnsupportedPlatformError, "Bubblewrap sandboxing is supported only on Linux" unless @platform.include?("linux")
        unless File.file?(@bubblewrap) && File.executable?(@bubblewrap)
          raise DependencyError, "Bubblewrap sandboxing requires an executable at #{@bubblewrap}"
        end
        if effective_policy.sandbox_scoped?
          raise CapabilityError, "Bubblewrap supports only execution_scope: :command"
        end
        if effective_policy.network.allowlist? && (!File.file?(@socat) || !File.executable?(@socat))
          raise DependencyError, "filtered Bubblewrap egress requires socat at #{@socat}"
        end

        validate_mounts!
        capture_mount_identities!
        functional_probe!
        open_gateway(run:, transport: :unix, **@gateway_options)
        @opened = true
        self
      rescue
        close
        raise
      end

      # Stops the policy gateway. Calling +close+ more than once is safe.
      def close
        close_gateway
        @opened = false
        nil
      end

      # Executes +command+ in a fresh Bubblewrap namespace.
      def execute_program(command, timeout:, context: nil, max_output_bytes: nil,
        environment: {}, inherit_environment: false, scope: nil, cwd: nil)
        timeout = Float(timeout)
        raise ArgumentError, "timeout must be positive" unless timeout.positive? && timeout.finite?
        max_output_bytes ||= limits.output_bytes

        open unless @opened
        process, inherit = sandbox_process_command(
          command, scope:, cwd:, environment:, inherit_environment:
        )
        Sandbox::ProcessRunner.run(
          command: process,
          timeout:,
          context:,
          max_output_bytes:,
          environment: inherit ? ENV.to_h : {},
          inherit_environment: inherit
        )
      end

      # Replaces the current process with an interactively attached Bubblewrap
      # command after applying the same policy and scope validation as #execute.
      def exec_program(command, scope: nil, cwd: nil, environment: {}, inherit_environment: false)
        open unless @opened
        process, inherit = sandbox_process_command(
          command, scope:, cwd:, environment:, inherit_environment:
        )
        Kernel.exec(inherit ? ENV.to_h : {}, *process, unsetenv_others: !inherit)
      end

      # Returns the exact Bubblewrap policy arguments used before the command.
      def bubblewrap_args(mounts: effective_policy.effective_mounts(workspace), cwd: effective_policy.workspace_path,
        environment: effective_policy.environment.to_h, inherit_environment: effective_policy.environment.inherit?,
        network: effective_policy.network)
        mounts = protect_execution_mounts(mounts)
        args = %w[
          --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try
          --new-session --die-with-parent --cap-drop ALL --tmpfs /
        ]
        args << "--unshare-net" unless network.inherit?
        args.concat(runtime_mount_args)
        args.concat(%w[--dev /dev])
        args.concat(proc_args)
        @tmpfs.each { |path| args.concat(["--tmpfs", path]) }
        args.concat(directory_args(mounts.map(&:target) + @tmpfs + @masks + [cwd]))
        mounts.each do |mount|
          args.concat([mount.read_only? ? "--ro-bind" : "--bind", mount.source, mount.target])
        end
        @masks.each { |path| args.concat(["--tmpfs", path, "--remount-ro", path]) }
        args.concat(["--chdir", validated_cwd(cwd, mounts)])
        args << "--remount-ro" << "/" if effective_policy.root_filesystem == :read_only
        args << "--clearenv" unless inherit_environment
        environment.each { |name, value| args.concat(["--setenv", name, value]) }
        args.concat(["--uid", @uid.to_s]) if @uid
        args.concat(["--gid", @gid.to_s]) if @gid
        args
      end

      private

      def apply_setup!(run:)
        return if @setup_applied

        values = @setup.call(workspace:, run:)
        unless values.is_a?(Hash)
          raise PolicyError, "deferred sandbox setup must return a Hash"
        end
        values = values.transform_keys(&:to_sym)
        unknown = values.keys - %i[policy profiles]
        raise PolicyError, "unknown deferred sandbox setup options: #{unknown.join(", ")}" unless unknown.empty?

        @policy = Sandbox::Policy.coerce(values.fetch(:policy))
        @effective_policy = policy_with_network_default(@policy)
        configure_profiles!(values.fetch(:profiles, {}))
        @setup_applied = true
      end

      def sandbox_process_command(command, scope:, cwd:, environment:, inherit_environment:)
        configured_environment, inherit = execution_environment(environment, inherit_environment)
        selected_network = scope&.network || effective_policy.network
        gateway = @gateway if selected_network&.allowlist?
        gateway&.validate!
        configured_environment = gateway.environment.merge(configured_environment) if gateway
        mounts = execution_mounts(scope)
        mounts += Array(gateway&.mounts).map { |mount| Sandbox::Mount.coerce(mount) }
        process_command = wrap_command(command, scope:)
        process_command = gateway_command(process_command) if gateway
        args = bubblewrap_args(
          mounts:,
          cwd: cwd || effective_policy.workspace_path,
          environment: configured_environment,
          inherit_environment: inherit,
          network: selected_network
        )
        [[@bubblewrap, *args, "--", *process_command], inherit]
      end

      def wrap_command(command, scope:)
        command = Array(command).map(&:to_s)
        return command unless @command_wrapper
        if @command_wrapper.respond_to?(:call)
          Array(@command_wrapper.call(argv: command, workspace:, scope:)).map(&:to_s)
        else
          [*Array(@command_wrapper).map(&:to_s), *command]
        end
      end

      def normalize_proc(value)
        value = value.to_sym if value.is_a?(String)
        return value if %i[new none].include?(value)
        return Sandbox::Mount.coerce(value.merge(target: "/proc")) if value.is_a?(Hash)

        raise PolicyError, "Bubblewrap proc must be :new, :none, or a mount declaration"
      end

      def normalize_identity(value, name)
        return if value.nil?

        value = Integer(value)
        raise PolicyError, "Bubblewrap #{name} must be non-negative" if value.negative?

        value
      rescue ArgumentError, TypeError
        raise PolicyError, "Bubblewrap #{name} must be an integer"
      end

      def proc_args
        case @proc
        when :new then %w[--proc /proc]
        when :none then []
        else [@proc.read_only? ? "--ro-bind" : "--bind", @proc.source, "/proc"]
        end
      end

      def validate_mounts!
        effective_policy.effective_mounts(workspace).each do |mount|
          unless File.directory?(mount.source)
            raise PolicyError, "sandbox mount source is not a directory: #{mount.source}"
          end
        end
      end

      def functional_probe!
        result = Sandbox::ProcessRunner.run(
          command: [@bubblewrap, "--unshare-user", "--unshare-pid", "--new-session", "--die-with-parent", "--ro-bind", "/", "/", "--", "/bin/true"],
          timeout: 5,
          max_output_bytes: 16_384
        )
        return if result.success?

        detail = result.stderr.to_s.lines.first.to_s.strip
        detail = "the namespace probe failed" if detail.empty?
        raise DependencyError, "Bubblewrap is installed but unavailable: #{detail}"
      end

      def runtime_mount_args
        args = []
        @runtime_roots.each do |path|
          args.concat(["--ro-bind", path, path]) if File.directory?(path)
        end
        COMPATIBILITY_ROOTS.each do |path|
          if File.symlink?(path)
            args.concat(["--symlink", File.readlink(path), path])
          elsif File.directory?(path)
            args.concat(["--ro-bind", path, path])
          end
        end
        args
      end

      def directory_args(paths)
        paths.flat_map do |path|
          components = path.split("/").reject(&:empty?)
          components[0...-1].each_index.map do |index|
            ["--dir", "/#{components.first(index + 1).join("/")}"]
          end
        end.uniq.flatten
      end

      def validated_cwd(cwd, mounts)
        value = Sandbox::Mount.send(:normalize_virtual_path, cwd)
        return value if mounts.any? { |mount| mount.covers?(value) }
        return value if @tmpfs.any? { |path| value == path || value.start_with?("#{path}/") }

        raise PolicyError, "sandbox working directory is outside the selected scope"
      end

      def gateway_command(command)
        script = <<~SH
          set -eu
          relay="$1"
          socket="$2"
          shift 2
          "$relay" TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork "UNIX-CONNECT:$socket" &
          relay_pid=$!
          trap 'kill "$relay_pid" 2>/dev/null || true' EXIT INT TERM
          sleep 0.05
          "$@"
        SH
        ["/bin/sh", "-c", script, "little-ghost-egress", @socat, @gateway.proxy_mount_path, *Array(command).map(&:to_s)]
      end
    end
  end
end

LittleGhost::Sandbox.register_provider(:bubblewrap, LittleGhost::Sandboxes::Bubblewrap)
