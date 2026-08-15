# frozen_string_literal: true

require "tmpdir"
require "test_helper"
require "little_ghost/sandboxes/bubblewrap"
require "little_ghost/sandboxes/docker"

class SandboxBackendsTest < Minitest::Test
  Result = LittleGhost::Sandbox::Execution

  class ProbeBubblewrap < LittleGhost::Sandboxes::Bubblewrap
    private

    def functional_probe! = nil
  end

  class RecordingDocker < LittleGhost::Sandboxes::Docker
    attr_reader :commands

    def initialize(**options)
      super
      @commands = []
    end

    private

    def docker_command(*arguments, **)
      @commands << arguments
      if arguments.take(2) == ["create", "--name"]
        Result.new(stdout: "container-id\n", stderr: "", exit_code: 0)
      else
        Result.new(stdout: "", stderr: "", exit_code: 0)
      end
    end
  end

  class FailingCleanupDocker < RecordingDocker
    private

    def docker_command(*arguments, **options)
      return Result.new(stdout: "", stderr: "removal refused\n", exit_code: 1) if arguments.first == "rm"
      return Result.new(stdout: "{}", stderr: "", exit_code: 0) if arguments.take(2) == ["container", "inspect"]

      super
    end
  end

  class RetryEphemeralCleanupDocker < RecordingDocker
    attr_reader :removals

    def initialize(**options)
      super
      @removals = 0
    end

    private

    def docker_command(*arguments, **options)
      if arguments.first == "run"
        File.write(arguments.fetch(arguments.index("--cidfile") + 1), "ephemeral-id")
        raise LittleGhost::ToolError, "docker client interrupted"
      end
      if arguments.first == "rm"
        @removals += 1
        return Result.new(stdout: "", stderr: "removal refused\n", exit_code: 1) if @removals == 1
      end
      return Result.new(stdout: "{}", stderr: "", exit_code: 0) if arguments.take(2) == ["container", "inspect"]

      super
    end
  end

  def test_bubblewrap_rejects_non_linux_platforms
    Dir.mktmpdir do |root|
      sandbox = LittleGhost::Sandboxes::Bubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: "/missing/bwrap",
        platform: "arm64-darwin"
      )

      error = assert_raises(LittleGhost::UnsupportedPlatformError) { sandbox.open }

      assert_includes error.message, "only on Linux"
    end
  end

  def test_backends_validate_timeouts_before_startup
    Dir.mktmpdir do |root|
      bubblewrap = LittleGhost::Sandboxes::Bubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: "/missing/bwrap",
        platform: "arm64-darwin"
      )
      docker = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never
      )

      assert_raises(ArgumentError) { bubblewrap.execute_program(["true"], timeout: 0) }
      assert_raises(ArgumentError) { docker.execute_program(["true"], timeout: Float::NAN) }
      assert_empty docker.commands
    end
  end

  def test_bubblewrap_builds_a_networkless_read_only_policy
    Dir.mktmpdir do |root|
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: executable,
        platform: "x86_64-linux"
      )

      sandbox.open
      arguments = sandbox.bubblewrap_args

      assert_includes arguments, "--unshare-net"
      assert_includes arguments, "--ro-bind"
      assert_includes arguments, "--remount-ro"
      assert_equal :none, sandbox.effective_policy.network.mode
    end
  end

  def test_bubblewrap_applies_deferred_policy_profiles_and_layout_options
    Dir.mktmpdir do |root|
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      called = false
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: executable,
        platform: "x86_64-linux",
        setup: lambda do |workspace:, run:|
          called = true
          assert_equal root, workspace.root
          assert_equal :run, run
          {
            policy: {workspace_access: :read_write, network: :none},
            profiles: {read_only: {mounts: [{target: "/workspace", access: :read_only}]}}
          }
        end,
        proc: {source: "/proc", access: :read_only},
        masks: ["/workspace/private"],
        uid: 1000,
        gid: 1001
      )

      sandbox.open(run: :run)
      arguments = sandbox.bubblewrap_args(mounts: sandbox.scope(:read_only).mounts)

      assert called
      assert_includes arguments.each_cons(3).to_a, ["--ro-bind", "/proc", "/proc"]
      assert_includes arguments.each_cons(2).to_a, ["--tmpfs", "/workspace/private"]
      assert_includes arguments.each_cons(2).to_a, ["--uid", "1000"]
      assert_includes arguments.each_cons(2).to_a, ["--gid", "1001"]
      assert sandbox.scope(:read_only).mounts.first.read_only?
    end
  end

  def test_bubblewrap_applies_gateway_only_to_network_enabled_scopes
    Dir.mktmpdir do |root|
      socket_root = File.join(root, "gateway")
      Dir.mkdir(socket_root)
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        command_wrapper: ["/usr/bin/wrapper"],
        policy: {network: {mode: :allowlist, allow: ["example.com:443"]}},
        profiles: {connected: {network: true}, offline: {network: false}}
      )
      gateway = LittleGhost::Network::ExternalGateway.new(
        policy: sandbox.effective_policy.network,
        mounts: [{source: socket_root, target: "/run/gateway"}],
        proxy_mount_path: "/run/gateway/proxy.sock",
        environment: {"HTTPS_PROXY" => "http://127.0.0.1:3128"}
      )
      sandbox.instance_variable_set(:@gateway, gateway)

      connected, = sandbox.send(
        :sandbox_process_command,
        ["true"],
        scope: sandbox.scope(:connected),
        cwd: nil,
        environment: {},
        inherit_environment: false
      )
      offline, = sandbox.send(
        :sandbox_process_command,
        ["true"],
        scope: sandbox.scope(:offline),
        cwd: nil,
        environment: {},
        inherit_environment: false
      )

      assert_includes connected, "/run/gateway/proxy.sock"
      assert_includes connected, "--unshare-net"
      assert_includes connected.each_cons(3).to_a, ["--setenv", "HTTPS_PROXY", "http://127.0.0.1:3128"]
      assert_includes connected, "/usr/bin/wrapper"
      refute_includes offline, "/run/gateway/proxy.sock"
      assert_includes offline, "--unshare-net"
      refute_includes offline, "HTTPS_PROXY"
      assert_includes offline, "/usr/bin/wrapper"
    end
  end

  def test_bubblewrap_scope_can_narrow_inherited_network_to_none
    Dir.mktmpdir do |root|
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {network: :inherit},
        profiles: {offline: {network: false}}
      )

      command, = sandbox.send(
        :sandbox_process_command,
        ["true"],
        scope: sandbox.scope(:offline),
        cwd: nil,
        environment: {},
        inherit_environment: false
      )

      assert_includes command, "--unshare-net"
    end
  end

  def test_bubblewrap_rejects_a_persistent_execution_scope
    Dir.mktmpdir do |root|
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {execution_scope: :sandbox},
        bubblewrap: executable,
        platform: "x86_64-linux"
      )

      assert_raises(LittleGhost::CapabilityError) { sandbox.open }
    end
  end

  def test_docker_command_scope_uses_ephemeral_networkless_containers
    Dir.mktmpdir do |root|
      sandbox = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never
      )

      sandbox.open
      sandbox.execute_program(["ruby", "-v"], timeout: 5)

      run = sandbox.commands.find { |command| command.first == "run" }
      assert_includes run, "--rm"
      assert_includes run, "--read-only"
      assert_includes run.each_cons(2).to_a, ["--cap-drop", "ALL"]
      assert_includes run.each_cons(2).to_a, ["--security-opt", "no-new-privileges"]
      assert_includes run.each_cons(2).to_a, ["--pids-limit", "256"]
      assert_includes run, "--user"
      assert_equal ["--network", "none"], run.each_cons(2).find { |pair| pair.first == "--network" }
      assert run.each_cons(2).any? { |pair| pair.first == "--mount" && pair.last.include?("readonly") }
    end
  end

  def test_docker_scope_can_narrow_inherited_network_to_none
    Dir.mktmpdir do |root|
      sandbox = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never,
        policy: {network: :inherit},
        profiles: {offline: {network: false}}
      )

      sandbox.execute_program(["true"], timeout: 5, scope: sandbox.scope(:offline))

      run = sandbox.commands.find { |command| command.first == "run" }
      assert_includes run.each_cons(2).to_a, ["--network", "none"]
    end
  end

  def test_bubblewrap_protects_read_only_mounts_through_writable_physical_aliases
    Dir.mktmpdir do |root|
      attachments = File.join(root, "attachments")
      Dir.mkdir(attachments)
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: executable,
        platform: "x86_64-linux",
        policy: {
          workspace_access: :read_write,
          mounts: [{
            source: attachments,
            target: "/attachments",
            access: :read_only,
            protect_aliases: true
          }]
        }
      )

      arguments = sandbox.bubblewrap_args
      bindings = arguments.each_cons(3).select { |flag, _source, _target| %w[--bind --ro-bind].include?(flag) }

      assert_includes bindings, ["--bind", root, "/workspace"]
      assert_includes bindings, ["--ro-bind", attachments, "/workspace/attachments"]
      assert_operator bindings.index(["--bind", root, "/workspace"]), :<,
        bindings.index(["--ro-bind", attachments, "/workspace/attachments"])
    end
  end

  def test_bubblewrap_rejects_a_replaced_narrowed_mount_source
    Dir.mktmpdir do |root|
      outside = Dir.mktmpdir
      narrowed = File.join(root, "narrowed")
      displaced = File.join(root, "displaced")
      Dir.mkdir(narrowed)
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      sandbox = ProbeBubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: executable,
        platform: "x86_64-linux",
        policy: {workspace_access: :read_write}
      )
      scope = sandbox.scope(mounts: ["/workspace/narrowed"])
      File.rename(narrowed, displaced)
      File.symlink(outside, narrowed)

      error = assert_raises(LittleGhost::CapabilityError) do
        sandbox.execute_program(["true"], timeout: 5, scope:)
      end

      assert_match(/changed after initialization/, error.message)
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_docker_rejects_an_option_as_its_image
    Dir.mktmpdir do |root|
      assert_raises(LittleGhost::PolicyError) do
        LittleGhost::Sandboxes::Docker.new(
          workspace: LittleGhost::Workspace.new(root:),
          image: "--privileged"
        )
      end
    end
  end

  def test_docker_mounts_parent_before_nested_read_only_mount
    Dir.mktmpdir do |root|
      attachments = File.join(root, "attachments")
      Dir.mkdir(attachments)
      sandbox = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never,
        policy: {
          workspace_access: :read_write,
          mounts: [{source: attachments, target: "/workspace/attachments", access: :read_only}]
        }
      )

      sandbox.execute_program(["true"], timeout: 5)

      run = sandbox.commands.find { |command| command.first == "run" }
      mounted_targets = run.each_cons(2).filter_map do |flag, value|
        value[/dst=([^,]+)/, 1] if flag == "--mount"
      end
      assert_equal ["/workspace", "/workspace/attachments"], mounted_targets
    end
  end

  def test_docker_sandbox_scope_owns_one_container_until_close
    Dir.mktmpdir do |root|
      sandbox = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never,
        policy: {execution_scope: :sandbox}
      )

      sandbox.open
      assert_equal "container-id", sandbox.container_id

      sandbox.execute_program(["ruby", "-v"], timeout: 5)
      assert sandbox.commands.any? { |command| command.first == "exec" }

      sandbox.close
      assert sandbox.commands.any? { |command| command.take(3) == ["rm", "--force", "container-id"] }
      assert_nil sandbox.container_id
    end
  end

  def test_persistent_docker_accepts_a_logically_identical_scope
    Dir.mktmpdir do |root|
      sandbox = RecordingDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never,
        policy: {execution_scope: :sandbox}
      )

      sandbox.open
      sandbox.execute_program(["true"], timeout: 5, scope: sandbox.scope)

      assert sandbox.commands.any? { |command| command.first == "exec" }
    ensure
      sandbox&.close
    end
  end

  def test_failed_docker_cleanup_retains_resource_ownership_for_retry
    Dir.mktmpdir do |root|
      sandbox = FailingCleanupDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never,
        policy: {execution_scope: :sandbox}
      )
      sandbox.open

      error = assert_raises(LittleGhost::CleanupError) { sandbox.close }

      assert_match(/could not remove sandbox container/, error.message)
      assert_equal "container-id", sandbox.container_id
    end
  end

  def test_failed_ephemeral_cleanup_is_retried_by_close
    Dir.mktmpdir do |root|
      sandbox = RetryEphemeralCleanupDocker.new(
        workspace: LittleGhost::Workspace.new(root:),
        image: "ruby:test",
        pull: :never
      )

      assert_raises(LittleGhost::CleanupError) do
        sandbox.execute_program(["true"], timeout: 5)
      end

      sandbox.close
      assert_equal 2, sandbox.removals
    end
  end
end
