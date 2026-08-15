# frozen_string_literal: true

require "securerandom"
require "tempfile"
require_relative "../sandbox/process_runner"
require_relative "../sandbox/isolated_backend"

module LittleGhost
  module Sandboxes
    # Runs commands in Docker containers with explicit mounts, environment, and
    # network policy. Selecting this backend requires a reachable Docker daemon.
    class Docker < Sandbox::IsolatedBackend
      DEFAULT_EXECUTABLE = "docker" # :nodoc:
      PULL_POLICIES = %i[if_missing never always].freeze # :nodoc:

      # Reports whether a reachable Docker daemon is available.
      def self.probe(executable: DEFAULT_EXECUTABLE)
        result = Sandbox::ProcessRunner.run(
          command: [executable, "info", "--format", "{{.ServerVersion}}"],
          timeout: 10,
          max_output_bytes: 16_384,
          environment: {"PATH" => ENV.fetch("PATH", "")}
        )
        if result.success?
          {available: true, reason: nil, capabilities: backend_capabilities}
        else
          reason = result.stderr.to_s.lines.first.to_s.strip
          {available: false, reason: reason.empty? ? "Docker daemon is unavailable" : reason, capabilities: Capabilities.new(features: [], network_modes: [])}
        end
      rescue ToolError
        {available: false, reason: "Docker daemon is unavailable", capabilities: Capabilities.new(features: [], network_modes: [])}
      end

      # Describes the isolation and operations provided by this backend.
      def self.backend_capabilities
        Capabilities.new(
          features: %i[
            filesystem_read filesystem_list filesystem_write filesystem_replace
            process_execute virtual_filesystem persistent_processes
          ],
          network_modes: %i[inherit none allowlist],
          isolation: :container
        )
      end

      # Builds a Docker sandbox for +image+.
      def initialize(workspace:, image:, policy: nil, profiles: {}, limits: {}, docker: DEFAULT_EXECUTABLE, pull: :if_missing,
        labels: {}, gateway_options: {}, user: "#{Process.uid}:#{Process.gid}", pids_limit: 256)
        super(workspace:, policy:, profiles:, limits:)
        @image = String(image)
        if @image.empty? || @image.start_with?("-")
          raise PolicyError, "Docker sandbox image must be a non-option image reference"
        end

        @docker = String(docker)
        @pull = pull.to_sym
        raise PolicyError, "Docker pull must be :if_missing, :never, or :always" unless PULL_POLICIES.include?(@pull)

        @sandbox_id = SecureRandom.uuid
        @labels = {"org.little-ghost.sandbox-id" => @sandbox_id}.merge(string_environment(labels))
        @container_name = "little-ghost-#{@sandbox_id}"
        @container_id = nil
        @ephemeral_container_ids = []
        @gateway_options = gateway_options
        @user = String(user)
        raise PolicyError, "Docker user must be a non-option user or uid" if @user.empty? || @user.start_with?("-")
        @pids_limit = Integer(pids_limit)
        raise PolicyError, "Docker pids_limit must be positive" unless @pids_limit.positive?
        @opened = false
      end

      # Container image selected by the application.
      attr_reader :image
      # Unique identifier applied to this sandbox and its Docker resources.
      attr_reader :sandbox_id
      # Persistent container identifier, or +nil+ for command-scoped policies.
      attr_reader :container_id

      # Returns this backend's declared capabilities.
      def capabilities = self.class.backend_capabilities

      # Validates dependencies and creates sandbox-scoped resources.
      def open(run: nil)
        return self if @opened

        validate_policy!
        capture_mount_identities!
        validate_daemon!
        ensure_image!
        open_gateway(run:, transport: :docker, docker: @docker, **@gateway_options)
        create_persistent_container! if effective_policy.sandbox_scoped?
        @opened = true
        self
      rescue
        close
        raise
      end

      # Removes owned containers, networks, and gateways.
      def close
        errors = []
        @ephemeral_container_ids.dup.each do |identifier|
          remove_container(identifier)
          @ephemeral_container_ids.delete(identifier)
        rescue CleanupError => error
          errors << error.message
        end
        if @container_id
          begin
            remove_container(@container_id)
            @container_id = nil
          rescue CleanupError => error
            errors << error.message
          end
        end
        begin
          close_gateway
        rescue CleanupError => error
          errors << error.message
        end
        @opened = false if @container_id.nil? && @gateway.nil?
        raise CleanupError, errors.join("; ") unless errors.empty?

        nil
      end

      # Executes +command+ in a fresh or sandbox-scoped container.
      def execute_program(command, timeout:, context: nil, max_output_bytes: nil,
        environment: {}, inherit_environment: false, scope: nil, cwd: nil)
        timeout = Float(timeout)
        raise ArgumentError, "timeout must be positive" unless timeout.positive? && timeout.finite?
        max_output_bytes ||= limits.output_bytes

        open unless @opened
        selected_network = scope&.network || effective_policy.network
        if effective_policy.sandbox_scoped? && selected_network != effective_policy.network
          raise CapabilityError, "a persistent Docker container cannot narrow network access between commands"
        end
        gateway = @gateway if selected_network.allowlist?
        gateway&.validate!
        configured_environment, inherit = execution_environment(environment, inherit_environment)
        configured_environment = ENV.to_h.merge(configured_environment) if inherit
        configured_environment = gateway.environment.merge(configured_environment) if gateway
        mounts = execution_mounts(scope)
        mounts += Array(gateway&.mounts).map { |mount| Sandbox::Mount.coerce(mount) }
        if effective_policy.sandbox_scoped? && scope && mounts != persistent_mounts
          raise CapabilityError, "a persistent Docker container cannot narrow mounts between commands"
        end
        workdir = validated_cwd(cwd || effective_policy.workspace_path, mounts)
        if effective_policy.command_scoped?
          execute_ephemeral(
            command,
            mounts:,
            workdir:,
            environment: configured_environment,
            network: selected_network,
            timeout:,
            context:,
            max_output_bytes:
          )
        else
          execute_persistent(
            command,
            workdir:,
            environment: configured_environment,
            timeout:,
            context:,
            max_output_bytes:
          )
        end
      end

      private

      def validate_policy!
        effective_policy.effective_mounts(workspace).each do |mount|
          raise PolicyError, "sandbox mount source is not a directory: #{mount.source}" unless File.directory?(mount.source)
          if mount.source.include?(",") || mount.target.include?(",")
            raise PolicyError, "Docker mount paths cannot contain commas"
          end
        end
      end

      def validate_daemon!
        result = docker_command("info", "--format", "{{.ServerVersion}}", timeout: 10)
        return if result.success?

        detail = result.stderr.to_s.lines.first.to_s.strip
        detail = "the daemon did not respond" if detail.empty?
        raise DependencyError, "Docker sandboxing requires a reachable daemon: #{detail}"
      rescue Errno::ENOENT
        raise DependencyError, "Docker sandboxing requires #{@docker} on PATH"
      end

      def ensure_image!
        present = docker_command("image", "inspect", @image, timeout: 30).success?
        if @pull == :always || (@pull == :if_missing && !present)
          result = docker_command("pull", @image, timeout: 600, max_output_bytes: 1_000_000)
          raise DependencyError, "Docker could not pull #{@image}: #{first_error(result)}" unless result.success?
        elsif !present
          raise DependencyError, "Docker image #{@image} is not available and pull is :never"
        end
      end

      def create_persistent_container!
        result = docker_command(
          "create", "--name", @container_name,
          *container_options(persistent_mounts, effective_policy.environment.to_h, network: effective_policy.network),
          @image, "/bin/sh", "-c", "trap 'exit 0' TERM INT; while :; do sleep 3600; done",
          timeout: 60
        )
        raise DependencyError, "Docker could not create the sandbox container: #{first_error(result)}" unless result.success?

        @container_id = result.stdout.strip
        started = docker_command("start", @container_id, timeout: 60)
        raise DependencyError, "Docker could not start the sandbox container: #{first_error(started)}" unless started.success?
      end

      def execute_ephemeral(command, mounts:, workdir:, environment:, network:, timeout:, context:, max_output_bytes:)
        Tempfile.create(["little-ghost-docker", ".cid"]) do |cidfile|
          cidfile.close
          File.unlink(cidfile.path)
          begin
            result = docker_command(
              "run", "--rm", "--cidfile", cidfile.path,
              *container_options(mounts, environment, network:),
              "--workdir", workdir,
              @image, *Array(command).map(&:to_s),
              timeout:, context:, max_output_bytes:
            )
            if result.respond_to?(:timed_out) && result.timed_out && File.file?(cidfile.path)
              remove_ephemeral_container(File.read(cidfile.path).strip)
            end
            return result
          rescue
            remove_ephemeral_container(File.read(cidfile.path).strip) if File.file?(cidfile.path)
            raise
          ensure
            File.unlink(cidfile.path) if File.file?(cidfile.path)
          end
        end
      end

      def execute_persistent(command, workdir:, environment:, timeout:, context:, max_output_bytes:)
        result = docker_command(
          "exec", "--workdir", workdir,
          *environment.flat_map { |name, value| ["--env", "#{name}=#{value}"] },
          @container_id, *Array(command).map(&:to_s),
          timeout:, context:, max_output_bytes:
        )
        if result.respond_to?(:timed_out) && result.timed_out
          remove_container(@container_id)
          @container_id = nil
          @opened = false
        end
        result
      rescue
        remove_container(@container_id)
        @container_id = nil
        @opened = false
        raise
      end

      def persistent_mounts
        execution_mounts(nil) + Array(@gateway&.mounts).map { |mount| Sandbox::Mount.coerce(mount) }
      end

      def container_options(mounts, environment, network:)
        options = [
          "--init", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
          "--pids-limit", @pids_limit.to_s, "--user", @user
        ]
        options << "--read-only" if effective_policy.root_filesystem == :read_only
        options.concat(["--tmpfs", "/tmp:rw,noexec,nosuid,nodev", "--tmpfs", "/run:rw,noexec,nosuid,nodev"])
        options.concat(["--network", "none"]) if network.none?
        if network.allowlist?
          client_network = @gateway.client_network
          unless client_network
            raise CapabilityError, "Docker allowlist gateways must provide an isolated client network"
          end
          options.concat(["--network", client_network])
        end
        @labels.each { |name, value| options.concat(["--label", "#{name}=#{value}"]) }
        mounts.each do |mount|
          specification = "type=bind,src=#{mount.source},dst=#{mount.target}"
          specification += ",readonly" if mount.read_only?
          options.concat(["--mount", specification])
        end
        environment.each { |name, value| options.concat(["--env", "#{name}=#{value}"]) }
        options
      end

      def docker_command(*arguments, timeout:, context: nil, max_output_bytes: 100_000)
        Sandbox::ProcessRunner.run(
          command: [@docker, *arguments],
          timeout:,
          context:,
          max_output_bytes:,
          environment: docker_environment,
          inherit_environment: false
        )
      end

      def remove_container(identifier)
        return if identifier.to_s.empty?

        result = docker_command("rm", "--force", identifier, timeout: 30)
        return if result.success?

        inspection = docker_command("container", "inspect", identifier, timeout: 10)
        return if !inspection.success? && first_error(inspection).match?(/no such (?:object|container)/i)

        detail = inspection.success? ? first_error(result) : "cleanup could not be verified: #{first_error(inspection)}"
        raise CleanupError, "Docker could not remove sandbox container #{identifier}: #{detail}"
      rescue ToolError => error
        raise CleanupError, "Docker could not remove sandbox container #{identifier}: #{error.message}"
      end

      def remove_ephemeral_container(identifier)
        remove_container(identifier)
        @ephemeral_container_ids.delete(identifier)
      rescue CleanupError
        @ephemeral_container_ids << identifier unless @ephemeral_container_ids.include?(identifier)
        raise
      end

      def validated_cwd(cwd, mounts)
        value = Sandbox::Mount.send(:normalize_virtual_path, cwd)
        return value if mounts.any? { |mount| mount.covers?(value) }

        raise PolicyError, "sandbox working directory is outside the selected scope"
      end

      def first_error(result)
        result.stderr.to_s.lines.first.to_s.strip.then { |line| line.empty? ? "unknown Docker error" : line }
      end

      def docker_environment
        %w[PATH HOME DOCKER_HOST DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH].each_with_object({}) do |name, values|
          value = ENV[name]
          values[name] = value if value && !value.empty?
        end
      end
    end
  end
end

LittleGhost::Sandbox.register_provider(:docker, LittleGhost::Sandboxes::Docker)
