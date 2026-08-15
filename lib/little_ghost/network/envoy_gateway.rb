# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "json"
require "securerandom"
require "tmpdir"
require_relative "../sandbox/process_runner"
require_relative "authorizer_server"
require_relative "certificate_authority"
require_relative "envoy_config"

module LittleGhost
  module Network
    # Manages Envoy as a native process or pinned Docker sidecar for one Sandbox.
    class EnvoyGateway < Gateway
      ENVOY_IMAGE = "envoyproxy/envoy:v1.39.0@sha256:d59f7f5fa10cff6d5892b6c5e7df5c9297ddfb2c3683e33fbfb82da24de4fa66" # :nodoc:
      RUNTIMES = %i[auto native docker].freeze # :nodoc:
      TRANSPORTS = %i[unix docker].freeze # :nodoc:

      # Builds a run-scoped Envoy gateway. Envoy remains an optional external
      # dependency and the Docker image is pinned by digest by default.
      def initialize(policy:, runtime: :auto, transport: :unix, envoy: "envoy", docker: "docker",
        image: ENVOY_IMAGE, pull: :if_missing, dns: [])
        super(policy:)
        @runtime = runtime.to_sym
        @transport = transport.to_sym
        raise PolicyError, "Envoy runtime must be :auto, :native, or :docker" unless RUNTIMES.include?(@runtime)
        raise PolicyError, "Envoy transport must be :unix or :docker" unless TRANSPORTS.include?(@transport)

        @envoy = String(envoy)
        @docker = String(docker)
        @image = String(image)
        @pull = pull.to_sym
        raise PolicyError, "Envoy image must be a non-option image reference" if @image.empty? || @image.start_with?("-")
        raise PolicyError, "Envoy pull must be :if_missing, :never, or :always" unless %i[if_missing never always].include?(@pull)

        @dns = Array(dns).map do |address|
          address = String(address)
          IPAddr.new(address)
          address.freeze
        rescue IPAddr::InvalidAddressError
          raise PolicyError, "Envoy DNS resolvers must be IP addresses"
        end.freeze
        @gateway_id = SecureRandom.uuid
        @opened = false
      end

      # Host path of the explicit proxy's Unix socket, when used.
      attr_reader :proxy_socket
      # Internal Docker network exposed only to sandbox clients, when used.
      attr_reader :client_network
      # Configured runtime selector: +:auto+, +:native+, or +:docker+.
      attr_reader :runtime

      # Creates configuration, trust material, and the Envoy process.
      def open(run: nil)
        return self if @opened

        @root = Dir.mktmpdir("little-ghost-egress-", "/tmp")
        File.chmod(0o700, @root)
        @client_root = File.join(@root, "client")
        Dir.mkdir(@client_root, 0o700)
        @proxy_socket = File.join(@client_root, "proxy.sock") if @transport == :unix
        @interceptor_socket = File.join(@root, "interceptor.sock")
        @authorizer_socket = File.join(@root, "authorizer.sock")
        @access_log = File.join(@root, "access.log")
        @envoy_log = File.join(@root, "envoy.log")
        File.write(@access_log, "")
        File.chmod(0o600, @access_log)
        @resolved_runtime = resolve_runtime
        validate_runtime!
        prepare_http_inspection(run)
        @config_path = File.join(@root, "envoy.json")
        File.open(@config_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{JSON.pretty_generate(configuration)}\n")
        end
        (@resolved_runtime == :native) ? start_native : start_docker
        wait_until_ready!
        @opened = true
        self
      rescue
        close
        raise
      end

      # Removes the process, containers, networks, sockets, and trust material.
      def close
        stop_native
        stop_docker
        @authorizer_server&.close
        FileUtils.remove_entry_secure(@root) if @root && File.exist?(@root)
        @root = nil
        @opened = false
        nil
      end

      # Returns proxy variables and, for inspection, child-scoped trust paths.
      def environment
        endpoint = if @transport == :docker
          "http://#{@container_name}:3128"
        else
          "http://127.0.0.1:3128"
        end
        values = {
          "HTTP_PROXY" => endpoint,
          "HTTPS_PROXY" => endpoint,
          "http_proxy" => endpoint,
          "https_proxy" => endpoint,
          "NO_PROXY" => "localhost,127.0.0.1",
          "no_proxy" => "localhost,127.0.0.1"
        }
        values.merge!(trust_environment) if @trust_paths
        values.freeze
      end

      # Returns the gateway files that must be mounted into the sandbox.
      def mounts
        return [] unless @transport == :unix || @trust_paths

        [{source: @client_root, target: "/run/little-ghost-egress", access: :read_only}].freeze
      end

      # Returns the proxy socket's stable path inside a mounted sandbox.
      def proxy_mount_path = "/run/little-ghost-egress/proxy.sock"

      private

      def prepare_http_inspection(run)
        return unless policy.inspection == :http

        hosts = EnvoyConfig.endpoints(policy.allow).map(&:first).uniq
        @trust_paths = CertificateAuthority.create(root: @root, trust_root: @client_root, hosts:)
        @authorizer_server = AuthorizerServer.new(
          socket_path: @authorizer_socket,
          authorizer: policy.authorizer,
          run:
        ).start
      end

      def configuration
        listener = if @transport == :docker
          EnvoyConfig.socket_address("0.0.0.0", 3128)
        else
          EnvoyConfig.pipe_address(@proxy_socket, 0o666)
        end
        EnvoyConfig.build(
          policy:,
          listener:,
          paths: {
            interceptor_socket: @interceptor_socket,
            authorizer_socket: @authorizer_socket,
            certificate_chain: @trust_paths&.fetch(:certificate_chain, nil),
            private_key: @trust_paths&.fetch(:private_key, nil),
            trusted_ca: (@resolved_runtime == :docker) ? "/etc/ssl/certs/ca-certificates.crt" : OpenSSL::X509::DEFAULT_CERT_FILE,
            access_log: @access_log
          }
        )
      end

      def resolve_runtime
        return @runtime unless @runtime == :auto
        return :docker if @transport == :docker

        native_available? ? :native : :docker
      end

      def validate_runtime!
        if @transport == :docker && @resolved_runtime != :docker
          raise CapabilityError, "Docker network transport requires the Docker Envoy runtime"
        end
        if policy.inspection == :http && @resolved_runtime == :docker
          raise CapabilityError,
            "HTTP inspection requires a native Envoy runtime with Unix sockets; Docker Envoy supports CONNECT allowlisting"
        end
      end

      def native_available?
        result = Sandbox::ProcessRunner.run(
          command: [@envoy, "--version"],
          timeout: 5,
          max_output_bytes: 16_384,
          environment: {"PATH" => ENV.fetch("PATH", "")}
        )
        result.success?
      rescue ToolError
        false
      end

      def start_native
        validate = Sandbox::ProcessRunner.run(
          command: [@envoy, "--mode", "validate", "--config-path", @config_path],
          timeout: 30,
          max_output_bytes: 100_000,
          environment: {"PATH" => ENV.fetch("PATH", "")}
        )
        raise DependencyError, "Envoy rejected the generated configuration: #{first_error(validate)}" unless validate.success?

        log = File.open(@envoy_log, "a", 0o600)
        @envoy_log_io = log
        @envoy_pid = Process.spawn(
          {"PATH" => ENV.fetch("PATH", "")},
          @envoy, "--config-path", @config_path, "--concurrency", "1",
          "--disable-hot-restart", "--log-level", "warn",
          out: log, err: log, pgroup: true, unsetenv_others: true
        )
      rescue Errno::ENOENT
        raise DependencyError, "filtered egress requires Envoy or Docker; #{@envoy} is unavailable"
      end

      def start_docker
        validate_docker!
        ensure_image!
        @container_name = "little-ghost-envoy-#{@gateway_id}"
        if @transport == :docker
          @client_network = "little-ghost-client-#{@gateway_id}"
          @egress_network = "little-ghost-egress-#{@gateway_id}"
          create_network(@client_network, internal: true)
          create_network(@egress_network, internal: false)
        end
        arguments = [
          "run", "--detach", "--name", @container_name, "--read-only",
          "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--pids-limit", "256",
          "--tmpfs", "/tmp:rw,noexec,nosuid,nodev",
          "--label", "org.little-ghost.gateway-id=#{@gateway_id}",
          "--mount", "type=bind,src=#{@root},dst=#{@root}",
          "--network", (@transport == :docker) ? @egress_network : "bridge",
          *@dns.flat_map { |address| ["--dns", address] }, @image,
          "--config-path", @config_path, "--concurrency", "1",
          "--disable-hot-restart", "--log-level", "warn"
        ]
        result = docker_command(*arguments, timeout: 60)
        raise DependencyError, "Docker could not start Envoy: #{first_error(result)}" unless result.success?
        if @client_network
          connected = docker_command("network", "connect", @client_network, @container_name, timeout: 30)
          raise DependencyError, "Docker could not attach Envoy client network: #{first_error(connected)}" unless connected.success?
        end
      end

      def validate_docker!
        result = docker_command("info", "--format", "{{.ServerVersion}}", timeout: 10)
        raise DependencyError, "filtered egress requires a reachable Docker daemon: #{first_error(result)}" unless result.success?
      end

      def ensure_image!
        present = docker_command("image", "inspect", @image, timeout: 30).success?
        if @pull == :always || (@pull == :if_missing && !present)
          pulled = docker_command("pull", @image, timeout: 600, max_output_bytes: 1_000_000)
          raise DependencyError, "Docker could not pull the pinned Envoy image: #{first_error(pulled)}" unless pulled.success?
        elsif !present
          raise DependencyError, "the pinned Envoy image is unavailable and pull is :never"
        end
      end

      def create_network(name, internal:)
        arguments = ["network", "create", "--label", "org.little-ghost.gateway-id=#{@gateway_id}"]
        arguments << "--internal" if internal
        result = docker_command(*arguments, name, timeout: 30)
        raise DependencyError, "Docker could not create the Envoy network: #{first_error(result)}" unless result.success?
      end

      def wait_until_ready!
        deadline = monotonic_time + 10
        loop do
          ready = if @resolved_runtime == :native
            File.socket?(@proxy_socket)
          elsif @transport == :unix
            File.socket?(@proxy_socket)
          else
            docker_command("inspect", "--format", "{{.State.Running}}", @container_name, timeout: 5).stdout.strip == "true"
          end
          return if ready
          raise DependencyError, "Envoy exited before becoming ready: #{gateway_failure}" unless gateway_alive?
          raise DependencyError, "Envoy did not become ready" if monotonic_time >= deadline

          sleep(0.05)
        end
      end

      def gateway_alive?
        if @resolved_runtime == :native
          Process.kill(0, @envoy_pid)
          true
        else
          docker_command("inspect", "--format", "{{.State.Running}}", @container_name, timeout: 5).stdout.strip == "true"
        end
      rescue Errno::ESRCH
        false
      end

      def gateway_failure
        if @resolved_runtime == :native
          File.read(@envoy_log).lines.last.to_s.strip
        else
          docker_command("logs", @container_name, timeout: 5).stderr.lines.last.to_s.strip
        end.then { |detail| detail.empty? ? "no diagnostic was reported" : detail }
      rescue ToolError, Errno::ENOENT
        "no diagnostic was reported"
      end

      def stop_native
        return unless @envoy_pid

        Process.kill("TERM", -@envoy_pid)
        deadline = monotonic_time + 2
        until monotonic_time >= deadline
          finished = Process.waitpid(@envoy_pid, Process::WNOHANG)
          break if finished
          sleep(0.01)
        end
        Process.kill("KILL", -@envoy_pid)
        Process.waitpid(@envoy_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      ensure
        @envoy_pid = nil
        @envoy_log_io&.close
        @envoy_log_io = nil
      end

      def stop_docker
        if @container_name
          remove_docker_resource(
            ["rm", "--force", @container_name],
            ["container", "inspect", @container_name],
            "Envoy container #{@container_name}"
          )
          @container_name = nil
        end
        if @client_network
          remove_docker_resource(
            ["network", "rm", @client_network],
            ["network", "inspect", @client_network],
            "Envoy client network #{@client_network}"
          )
          @client_network = nil
        end
        return unless @egress_network

        remove_docker_resource(
          ["network", "rm", @egress_network],
          ["network", "inspect", @egress_network],
          "Envoy egress network #{@egress_network}"
        )
        @egress_network = nil
      rescue ToolError => error
        raise CleanupError, "Docker gateway cleanup failed: #{error.message}"
      end

      def remove_docker_resource(remove_arguments, inspect_arguments, label)
        removed = docker_command(*remove_arguments, timeout: 30)
        return if removed.success?

        still_present = docker_command(*inspect_arguments, timeout: 10)
        if !still_present.success? && first_error(still_present).match?(/no such (?:object|container|network)/i)
          return
        end

        detail = still_present.success? ? first_error(removed) : "cleanup could not be verified: #{first_error(still_present)}"
        raise CleanupError, "Docker could not remove #{label}: #{detail}"
      end

      def docker_command(*arguments, timeout:, max_output_bytes: 100_000)
        Sandbox::ProcessRunner.run(
          command: [@docker, *arguments],
          timeout:,
          max_output_bytes:,
          environment: docker_environment
        )
      end

      def docker_environment
        %w[PATH HOME DOCKER_HOST DOCKER_CONFIG DOCKER_TLS_VERIFY DOCKER_CERT_PATH].each_with_object({}) do |name, values|
          value = ENV[name]
          values[name] = value if value && !value.empty?
        end
      end

      def trust_environment
        bundle = "/run/little-ghost-egress/ca-bundle.pem"
        certificate = "/run/little-ghost-egress/ca.crt"
        store = "/run/little-ghost-egress/ca.p12"
        {
          "SSL_CERT_FILE" => bundle,
          "CURL_CA_BUNDLE" => bundle,
          "REQUESTS_CA_BUNDLE" => bundle,
          "GIT_SSL_CAINFO" => bundle,
          "NODE_EXTRA_CA_CERTS" => certificate,
          "PIP_CERT" => bundle,
          "CARGO_HTTP_CAINFO" => bundle,
          "BUNDLE_SSL_CA_CERT" => bundle,
          "JAVA_TOOL_OPTIONS" => "-Djavax.net.ssl.trustStore=#{store} -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=PKCS12"
        }
      end

      def first_error(result)
        result.stderr.to_s.lines.first.to_s.strip.then { |line| line.empty? ? "unknown error" : line }
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
