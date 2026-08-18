# frozen_string_literal: true

require "test_helper"
require "shellwords"

class SandboxBackendsTest < Minitest::Test
  class ProbeBubblewrap < LittleGhost::Sandboxes::Bubblewrap
    private

    def functional_probe! = nil
  end

  def test_native_fails_closed_on_unsupported_platforms
    Dir.mktmpdir do |root|
      assert_raises(LittleGhost::UnsupportedPlatformError) do
        LittleGhost::Sandboxes::Native.new(
          workspace: LittleGhost::Workspace.new(root:),
          platform: "unknown-platform"
        )
      end
    end
  end

  def test_native_probe_reports_the_selected_platform_backend
    result = LittleGhost::Sandboxes::Native.probe(platform: "unknown-platform")

    refute result.fetch(:available)
    assert_match(/unavailable/, result.fetch(:reason))
  end

  def test_unrestricted_rejects_claimed_subprocess_denial
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)

      assert_raises(LittleGhost::CapabilityError) do
        sandbox.start_program([RbConfig.ruby, "-e", "exit"], allow_subprocesses: false)
      end
    ensure
      workspace&.close
    end
  end

  def test_bubblewrap_uses_identity_bindings_for_workspace_paths
    Dir.mktmpdir do |root|
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      workspace = LittleGhost::Workspace.new(root:, paths: {skills: "skills"}).open
      sandbox = ProbeBubblewrap.new(
        workspace:,
        bubblewrap: executable,
        platform: "x86_64-linux",
        policy: {files: {root: :read_write, skills: :read_only}, network: :none}
      ).open

      arguments = sandbox.bubblewrap_args

      assert_includes arguments.each_cons(3).to_a, ["--bind", root, root]
      assert_includes arguments.each_cons(3).to_a, ["--ro-bind", workspace.path(:skills), workspace.path(:skills)]
      assert_includes arguments, "--unshare-net"
    ensure
      sandbox&.close
      workspace&.close
    end
  end

  def test_bubblewrap_reports_owned_subprocess_support
    capabilities = LittleGhost::Sandboxes::Bubblewrap.backend_capabilities

    assert capabilities.supports?(:process_spawn)
    assert_equal :namespace, capabilities.isolation

    Dir.mktmpdir do |root|
      sandbox = LittleGhost::Sandboxes::Bubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        bubblewrap: "/missing/bwrap",
        platform: "x86_64-linux"
      )

      error = assert_raises(LittleGhost::CapabilityError) do
        sandbox.start_program(["true"], allow_subprocesses: false)
      end
      assert_includes error.message, "cannot prohibit"
    end
  end

  def test_bubblewrap_root_filesystem_modes_are_explicit
    Dir.mktmpdir do |root|
      executable = File.join(root, "bwrap")
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      workspace = LittleGhost::Workspace.new(root:).open

      isolated = ProbeBubblewrap.new(
        workspace:,
        bubblewrap: executable,
        platform: "x86_64-linux",
        policy: {files: {root: :read_write}, root_filesystem: :isolated}
      )
      host_readable = ProbeBubblewrap.new(
        workspace:,
        bubblewrap: executable,
        platform: "x86_64-linux",
        policy: {files: {root: :read_write}, root_filesystem: :read_only}
      )

      assert_includes isolated.bubblewrap_args.each_cons(2).to_a, ["--tmpfs", "/"]
      assert_includes host_readable.bubblewrap_args.each_cons(3).to_a, ["--ro-bind", "/", "/"]
      assert host_readable.supports?(:process_tree_ownership)

      nested = LittleGhost::Sandbox::Mount.new(
        source: root,
        target: "/tmp/tenant/runs/123",
        access: :read_write
      )
      nested_arguments = host_readable.bubblewrap_args(mounts: [nested], cwd: nested.target)
      assert_includes nested_arguments.each_cons(2).to_a, ["--dir", "/tmp/tenant"]
      assert_includes nested_arguments.each_cons(2).to_a, ["--dir", "/tmp/tenant/runs"]
    ensure
      workspace&.close
    end
  end

  def test_seatbelt_rejects_non_macos_platforms
    Dir.mktmpdir do |root|
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace: LittleGhost::Workspace.new(root:),
        platform: "x86_64-linux"
      )

      assert_raises(LittleGhost::UnsupportedPlatformError) { sandbox.open }
    end
  end

  def test_seatbelt_runs_the_active_ruby_without_host_environment
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)

    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :none}
      ).open

      result = sandbox.execute_program([RbConfig.ruby, "-e", "print 1"], timeout: 5)

      assert_predicate result, :success?
      assert_equal "1", result.stdout
    ensure
      sandbox&.close
      workspace&.close
    end
  end

  def test_seatbelt_can_deny_child_creation_without_disabling_ruby_threads
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)

    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :none}
      ).open
      source = <<~RUBY
        print Thread.new { "thread-ok" }.value
        begin
          Process.spawn("/bin/echo", "child")
        rescue Errno::EPERM
          print ":spawn-denied"
        end
      RUBY
      session = sandbox.start_program(
        [RbConfig.ruby, "-e", source],
        allow_subprocesses: false
      )
      session.close_write
      output = +""
      output << session.read(timeout: 0.05).stdout while session.alive?
      output << session.read(timeout: 0).stdout

      assert_equal "thread-ok:spawn-denied", output
      assert_predicate session.wait, :success?
      refute sandbox.supports?(:process_spawn)
    ensure
      session&.close
      sandbox&.close
      workspace&.close
    end
  end

  def test_seatbelt_runs_host_read_only_development_commands_with_subprocesses
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)
    skip "Apple Git is unavailable" unless system("/usr/bin/git", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |root|
      outside = Tempfile.new("little-ghost-host-read-only")
      outside.write("before")
      outside.flush
      File.write(File.join(root, "check.rb"), <<~RUBY)
        abort "uname failed" unless system("/usr/bin/uname", "-s")
        print File.read(#{outside.path.inspect})
        begin
          File.write(#{outside.path.inspect}, "after")
        rescue Errno::EPERM
          print ":write-denied"
        end
      RUBY
      system("/usr/bin/git", "init", "-q", root, exception: true)
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {
          files: {root: :read_write},
          root_filesystem: :read_only,
          environment: {inherit: false, set: {"PATH" => ENV.fetch("PATH")}},
          network: :none
        }
      ).open

      shell = sandbox.execute_program(
        ["/bin/bash", "-lc", "#{Shellwords.escape(RbConfig.ruby)} check.rb"],
        timeout: 10
      )
      git = sandbox.execute_program(["/usr/bin/git", "status", "--short"], timeout: 10)

      assert_predicate shell, :success?
      assert_includes shell.stdout, "Darwin"
      assert_includes shell.stdout, "before:write-denied"
      assert_equal "before", File.read(outside.path)
      assert_predicate git, :success?
      assert sandbox.supports?(:process_spawn)
      refute sandbox.supports?(:process_tree_ownership)

      process_only = sandbox.scope(capabilities: [:process_execute])
      denied = process_only.execute_program(
        [RbConfig.ruby, "-e", <<~RUBY],
          begin
            Process.spawn("/usr/bin/uname", "-s")
            print "spawned"
          rescue Errno::EPERM
            print "denied"
          end
        RUBY
        timeout: 5
      )
      assert_equal "denied", denied.stdout
    ensure
      outside&.close!
      sandbox&.close
      workspace&.close
    end
  end

  def test_seatbelt_denies_reads_outside_runtime_and_workspace_roots
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)

    Dir.mktmpdir do |root|
      outside = Tempfile.new("little-ghost-seatbelt-secret")
      outside.write("secret")
      outside.flush
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :none}
      ).open
      source = <<~RUBY
        paths = #{[outside.path, "/private/etc/hosts"].inspect}
        reads = paths.map { |path| begin; File.read(path); "read"; rescue Errno::EPERM; "denied"; end }
        metadata = begin; File.stat(paths.first); "stat"; rescue Errno::EPERM; "denied"; end
        print [*reads, metadata].join(":")
      RUBY

      result = sandbox.execute_program([RbConfig.ruby, "-e", source], timeout: 5)

      assert_predicate result, :success?
      assert_equal "denied:denied:denied", result.stdout
    ensure
      outside&.close!
      sandbox&.close
      workspace&.close
    end
  end

  def test_seatbelt_preserves_read_only_overlays_beneath_writable_paths
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)

    Dir.mktmpdir do |root|
      protected = File.join(root, "protected")
      FileUtils.mkdir_p(protected)
      target = File.join(protected, "value.txt")
      File.write(target, "before")
      workspace = LittleGhost::Workspace.new(root:, paths: {protected:}).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {files: {root: :read_write, protected: :read_only}, network: :none}
      ).open
      source = <<~RUBY
        begin
          File.write(#{target.inspect}, "after")
          print "wrote"
        rescue Errno::EPERM
          print "denied"
        end
      RUBY

      result = sandbox.execute_program([RbConfig.ruby, "-e", source], timeout: 5)

      assert_predicate result, :success?
      assert_equal "denied", result.stdout
      assert_equal "before", File.read(target)
    ensure
      sandbox&.close
      workspace&.close
    end
  end
end
