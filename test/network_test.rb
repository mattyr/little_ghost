# frozen_string_literal: true

require "json"
require "openssl"
require "socket"
require "tmpdir"
require "async"
require "test_helper"
require "little_ghost/network"
require "little_ghost/network/authorizer_server"
require "little_ghost/network/certificate_authority"
require "little_ghost/network/envoy_config"
require "little_ghost/network/envoy_gateway"

class NetworkTest < Minitest::Test
  def test_envoy_connect_config_allows_only_exact_authorities
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["rubygems.org:443", "registry.npmjs.org:443"]
    )

    config = LittleGhost::Network::EnvoyConfig.build(
      policy:,
      listener: LittleGhost::Network::EnvoyConfig.pipe_address("/tmp/proxy.sock")
    )
    serialized = JSON.generate(config)

    assert_includes serialized, '"exact":"rubygems.org:443"'
    assert_includes serialized, '"exact":"registry.npmjs.org:443"'
    assert_includes serialized, '"status":403'
    assert_includes serialized, '"resolved_address_filter"'
    refute_includes serialized, "ext_authz"
  end

  def test_envoy_config_rejects_ambiguous_or_unsafe_destinations
    ["*.example.com:443", "127.0.0.1:443", "example.com", "example.com:0"].each do |destination|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(mode: :allowlist, allow: [destination])

      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Network::EnvoyConfig.build(
          policy:,
          listener: LittleGhost::Network::EnvoyConfig.pipe_address("/tmp/proxy.sock")
        )
      end
    end
  end

  def test_http_inspection_adds_tls_and_external_authorization
    Dir.mktmpdir do |root|
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        allow: ["example.com:443"],
        inspection: :http,
        authorizer: ->(request:) { LittleGhost::Network::Decision.allow },
        forward_headers: ["git-protocol"],
        mutation_headers: ["authorization", "user-agent"]
      )
      paths = {
        interceptor_socket: File.join(root, "interceptor.sock"),
        authorizer_socket: File.join(root, "authorizer.sock"),
        certificate_chain: File.join(root, "leaf.crt"),
        private_key: File.join(root, "leaf.key"),
        trusted_ca: "/etc/ssl/certs/ca-certificates.crt",
        access_log: File.join(root, "access.log")
      }

      serialized = JSON.generate(LittleGhost::Network::EnvoyConfig.build(
        policy:,
        listener: LittleGhost::Network::EnvoyConfig.pipe_address(File.join(root, "proxy.sock")),
        paths:
      ))

      assert_includes serialized, "envoy.filters.http.ext_authz"
      assert_includes serialized, "git-protocol"
      assert_includes serialized, '"exact":"authorization"'
      refute_includes serialized, '"safe_regex":{"regex":"^[a-z0-9-]+$"}'
      assert_includes serialized, '"disallowed_headers"'
      assert_includes serialized, '"exact":"authorization"'
      assert_includes serialized, paths.fetch(:certificate_chain)
      refute_includes serialized, "%REQ(:PATH)%"
    end
  end

  def test_certificate_authority_creates_a_verifiable_leaf_for_each_host
    Dir.mktmpdir do |root|
      paths = LittleGhost::Network::CertificateAuthority.create(
        root:,
        hosts: %w[example.com api.example.com]
      )
      ca = OpenSSL::X509::Certificate.new(File.binread(paths.fetch(:ca_certificate)))
      leaf = OpenSSL::X509::Certificate.new(File.binread(paths.fetch(:certificate_chain)))
      store = OpenSSL::X509::Store.new
      store.add_cert(ca)

      assert store.verify(leaf)
      san = leaf.extensions.find { |extension| extension.oid == "subjectAltName" }.value
      assert_includes san, "DNS:example.com"
      assert_includes san, "DNS:api.example.com"
      assert_equal 0o600, File.stat(paths.fetch(:ca_key)).mode & 0o777
      assert_equal 0o600, File.stat(paths.fetch(:private_key)).mode & 0o777
      refute_equal File.dirname(paths.fetch(:private_key)), paths.fetch(:trust_root)
      assert_empty Dir.glob(File.join(paths.fetch(:trust_root), "*.key"))
    end
  end

  def test_certificate_authority_does_not_block_the_scheduler_thread
    started = Queue.new
    release = Queue.new
    operation_thread = nil
    scheduler_thread = nil
    result = nil

    Async do |task|
      scheduler_thread = Thread.current
      generation = task.async do
        LittleGhost::Network::CertificateAuthority.stub(:create_material, lambda { |**|
          operation_thread = Thread.current
          started << true
          release.pop
          {ca_certificate: "ca.pem"}
        }) do
          result = LittleGhost::Network::CertificateAuthority.create(root: "/tmp", hosts: ["example.test"])
        end
      end
      started.pop
      release << true
      generation.wait
    end.wait

    assert_equal({ca_certificate: "ca.pem"}, result)
    refute_same scheduler_thread, operation_thread
  ensure
    release&.push(true)
  end

  def test_docker_envoy_rejects_http_inspection_instead_of_weakening_it
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["example.com:443"],
      inspection: :http,
      authorizer: ->(request:) { LittleGhost::Network::Decision.allow }
    )
    gateway = LittleGhost::Network::EnvoyGateway.new(policy:, runtime: :docker, transport: :docker)
    gateway.instance_variable_set(:@resolved_runtime, :docker)

    error = assert_raises(LittleGhost::CapabilityError) { gateway.send(:validate_runtime!) }

    assert_match(/supports CONNECT allowlisting/, error.message)
  end

  def test_envoy_gateway_rejects_unsafe_runtime_options
    policy = LittleGhost::Sandbox::NetworkPolicy.new(
      mode: :allowlist,
      allow: ["example.com:443"]
    )

    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::EnvoyGateway.new(policy:, image: "--privileged")
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::EnvoyGateway.new(policy:, dns: ["resolver.example.com"])
    end
  end

  def test_external_gateway_exposes_only_declared_resources_and_validates_readiness
    Dir.mktmpdir do |root|
      ready = false
      policy = LittleGhost::Sandbox::NetworkPolicy.new(
        mode: :allowlist,
        allow: ["example.com:443"]
      )
      workspace = LittleGhost::Workspace.new(root:, paths: {egress: "egress"}).open
      gateway = LittleGhost::Network::ExternalGateway.new(
        policy:,
        workspace:,
        runtime_paths: [:egress],
        proxy_mount_path: File.join(workspace.path(:egress), "proxy.sock"),
        environment: {HTTPS_PROXY: "http://127.0.0.1:3128"},
        validate: -> { raise LittleGhost::DependencyError, "not ready" unless ready }
      )

      assert_raises(LittleGhost::DependencyError) { gateway.validate! }
      ready = true
      assert_same gateway, gateway.validate!
      assert_equal({"HTTPS_PROXY" => "http://127.0.0.1:3128"}, gateway.environment)
      assert_equal [:egress], gateway.runtime_paths
      assert_equal File.join(workspace.path(:egress), "proxy.sock"), gateway.proxy_mount_path

      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Network::ExternalGateway.new(
          policy:,
          workspace:,
          runtime_paths: [:egress],
          proxy_mount_path: "/outside/proxy.sock"
        )
      end
    ensure
      workspace&.close
    end
  end

  def test_authorizer_server_passes_normalized_metadata_and_mutates_headers
    Dir.mktmpdir do |root|
      received = Queue.new
      authorizer = lambda do |request:|
        received << request
        LittleGhost::Network::Decision.allow(
          set_headers: {"authorization" => "Bearer trusted"},
          remove_headers: ["x-untrusted"]
        )
      end
      socket_path = File.join(root, "authorizer.sock")
      server = LittleGhost::Network::AuthorizerServer.new(socket_path:, authorizer:).start

      client = UNIXSocket.new(socket_path)
      client.write("POST /v1/items?secret=no HTTP/1.1\r\nHost: API.EXAMPLE.COM:443\r\nX-Untrusted: value\r\n\r\n")
      response = client.read
      request = received.pop

      assert_equal "POST", request.method
      assert_equal "api.example.com", request.host
      assert_equal 443, request.port
      assert_includes response, "HTTP/1.0 200 OK"
      assert_includes response, "authorization: Bearer trusted"
      assert_includes response, "x-untrusted"
      assert_includes response, "authorization"
    ensure
      client&.close
      server&.close
    end
  end

  def test_authorizer_failure_is_fail_closed
    Dir.mktmpdir do |root|
      socket_path = File.join(root, "authorizer.sock")
      server = LittleGhost::Network::AuthorizerServer.new(
        socket_path:,
        authorizer: ->(request:) { raise "unavailable" }
      ).start

      client = UNIXSocket.new(socket_path)
      client.write("GET / HTTP/1.1\r\nHost: example.com:443\r\n\r\n")

      assert_includes client.read, "HTTP/1.0 503 Service Unavailable"
    ensure
      client&.close
      server&.close
    end
  end

  def test_authorizer_decisions_reject_header_injection_and_routing_mutations
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"x-safe\r\nx-injected" => "value"})
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"authorization" => "value\r\nx-injected: yes"})
    end
    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Network::Decision.allow(set_headers: {"host" => "internal.example"})
    end
  end
end
