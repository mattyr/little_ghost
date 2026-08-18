# frozen_string_literal: true

require "tmpdir"
require "rbconfig"
require_relative "../sandbox/isolated_backend"

module LittleGhost
  module Sandboxes
    # Runs child programs under macOS Seatbelt. Seatbelt grants access to the
    # workspace's existing physical paths; it does not create Linux-style bind
    # mounts or virtual path aliases. Seatbelt cannot own detached descendants,
    # so sessions deliberately deny child-process creation.
    class Seatbelt < Sandbox::IsolatedBackend
      DEFAULT_EXECUTABLE = "/usr/bin/sandbox-exec" # :nodoc:

      def self.probe(executable: DEFAULT_EXECUTABLE, platform: RUBY_PLATFORM)
        available = platform.include?("darwin") && File.executable?(executable)
        {
          available:,
          reason: available ? nil : "Seatbelt sandboxing requires macOS and #{executable}",
          capabilities: available ? backend_capabilities : Capabilities.new(features: [], network_modes: [])
        }
      end

      def self.backend_capabilities
        Capabilities.new(
          features: %i[filesystem_read filesystem_list filesystem_write filesystem_replace process_execute],
          network_modes: %i[inherit none],
          isolation: :seatbelt
        )
      end

      def initialize(workspace:, policy: nil, profiles: {}, limits: {},
        executable: DEFAULT_EXECUTABLE, platform: RUBY_PLATFORM)
        super(workspace:, policy: policy || {}, profiles:, limits:)
        @executable = File.expand_path(executable)
        @platform = platform
        @opened = false
      end

      def capabilities = self.class.backend_capabilities

      def open(run: nil)
        return self if @opened
        raise UnsupportedPlatformError, "Seatbelt sandboxing is supported only on macOS" unless @platform.include?("darwin")
        raise DependencyError, "Seatbelt sandboxing requires #{@executable}" unless File.executable?(@executable)
        if effective_policy.network&.allowlist?
          raise CapabilityError, "Seatbelt does not implement allowlisted network egress"
        end

        workspace.validate!
        @temporary_directory = Dir.mktmpdir("little-ghost-seatbelt-")
        @opened = true
        self
      rescue
        close
        raise
      end

      def close
        FileUtils.remove_entry(@temporary_directory) if @temporary_directory && File.exist?(@temporary_directory)
        @temporary_directory = nil
        @opened = false
        nil
      end

      def execute_program(command, timeout:, context: nil, max_output_bytes: nil,
        environment: {}, inherit_environment: false, scope: nil, cwd: nil)
        session = start_program(
          command,
          context:,
          environment:,
          inherit_environment:,
          scope:,
          cwd:,
          output_bytes: max_output_bytes
        )
        session.close_write
        stdout = +""
        stderr = +""
        deadline = monotonic_time + Float(timeout)
        while session.alive?
          context&.check!
          remaining = deadline - monotonic_time
          raise ToolError, "Command timed out after #{timeout} seconds" unless remaining.positive?

          chunk = session.read(timeout: [remaining, 0.05].min)
          stdout << chunk.stdout
          stderr << chunk.stderr
        end
        chunk = session.read(timeout: 0)
        stdout << chunk.stdout
        stderr << chunk.stderr
        status = session.wait
        Sandbox::Execution.new(stdout:, stderr:, exit_code: status&.exitstatus)
      ensure
        session&.close
      end

      def start_program(command, context: nil, environment: {}, inherit_environment: false,
        scope: nil, cwd: nil, output_bytes: nil, memory_bytes: nil, cpu_seconds: nil, file_bytes: nil, processes: nil,
        allow_subprocesses: false)
        if allow_subprocesses
          raise CapabilityError, "Seatbelt cannot safely own subprocess descendants"
        end

        open unless @opened
        selected_scope = scope || self.scope
        selected_scope.validate!
        configured_environment = workspace.environment
          .merge(effective_policy.environment.to_h)
          .merge(environment.transform_keys(&:to_s).transform_values(&:to_s))
          .merge("TMPDIR" => @temporary_directory)
        profile = seatbelt_profile(selected_scope, allow_subprocesses:)
        Sandbox::ProcessSession.new(
          command: [@executable, "-p", profile, "--", *Array(command).map(&:to_s)],
          environment: configured_environment,
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

      def seatbelt_profile(scope, allow_subprocesses: false)
        rules = [
          "(version 1)",
          "(deny default)",
          "(allow process-exec)",
          ("(allow process-fork)" if allow_subprocesses),
          "(allow signal (target self))",
          "(allow sysctl-read)",
          "(allow file-read* (literal \"/\"))",
          *runtime_parent_paths.map { |path| allow_literal_rule("file-read-metadata", path) },
          *grant_parent_paths(scope).map { |path| allow_literal_rule("file-read-metadata", path) },
          *runtime_roots.map { |path| allow_rule("file-read*", path) },
          *device_paths.map { |path| allow_literal_rule("file-read*", path) },
          *device_paths.map { |path| allow_literal_rule("file-write*", path) },
          allow_rule("file-read*", @temporary_directory),
          allow_rule("file-write*", @temporary_directory)
        ]
        rules.compact!
        scope.process_grants.each do |mount|
          rules << allow_rule("file-read*", mount.source)
          rules << allow_rule("file-write*", mount.source) if mount.writable?
        end
        scope.process_grants.select(&:read_only?).each do |mount|
          rules << deny_rule("file-write*", mount.source)
        end
        rules << "(allow network*)" if scope.network&.inherit?
        rules.join("\n")
      end

      def allow_rule(operation, path)
        path_variants(path).flat_map do |variant|
          escaped = variant.gsub("\\", "\\\\").gsub('"', '\\"')
          ["(allow #{operation} (literal \"#{escaped}\"))", "(allow #{operation} (subpath \"#{escaped}\"))"]
        end.join("\n")
      end

      def allow_literal_rule(operation, path)
        path_variants(path).map do |variant|
          escaped = variant.gsub("\\", "\\\\").gsub('"', '\\"')
          "(allow #{operation} (literal \"#{escaped}\"))"
        end.join("\n")
      end

      def deny_rule(operation, path)
        path_variants(path).flat_map do |variant|
          escaped = variant.gsub("\\", "\\\\").gsub('"', '\\"')
          ["(deny #{operation} (literal \"#{escaped}\"))", "(deny #{operation} (subpath \"#{escaped}\"))"]
        end.join("\n")
      end

      def path_variants(path)
        [File.expand_path(path), File.realpath(path)].uniq
      end

      def runtime_roots
        roots = %w[/System /usr /bin /sbin]
        roots.concat([RbConfig::CONFIG["prefix"], RbConfig::CONFIG["libdir"]])
        roots.concat(%w[/opt/homebrew/opt/gmp /usr/local/opt/gmp])
        roots.compact.select { |path| File.exist?(path) }.flat_map do |path|
          [File.expand_path(path), File.realpath(path)]
        end.uniq
      end

      def device_paths
        %w[/dev/null /dev/random /dev/urandom].select { |path| File.exist?(path) }
      end

      def runtime_parent_paths
        parent_paths(runtime_roots)
      end

      def grant_parent_paths(scope)
        parent_paths(scope.process_grants.map(&:source))
      end

      def parent_paths(roots)
        roots.flat_map do |root|
          parents = []
          path = File.dirname(File.expand_path(root))
          until path == File::SEPARATOR
            parents << path
            path = File.dirname(path)
          end
          parents
        end.uniq
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

LittleGhost::Sandbox.register_provider(:seatbelt, LittleGhost::Sandboxes::Seatbelt)
