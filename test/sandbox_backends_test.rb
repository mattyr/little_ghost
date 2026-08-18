# frozen_string_literal: true

require "test_helper"

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
    ensure
      session&.close
      sandbox&.close
      workspace&.close
    end
  end

  def test_seatbelt_rejects_subprocess_sessions
    skip "Seatbelt is only available on macOS" unless RUBY_PLATFORM.include?("darwin")
    skip "sandbox-exec is unavailable" unless LittleGhost::Sandboxes::Seatbelt.probe.fetch(:available)

    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:).open
      sandbox = LittleGhost::Sandboxes::Seatbelt.new(
        workspace:,
        policy: {files: {root: :read_write}, network: :none}
      ).open

      error = assert_raises(LittleGhost::CapabilityError) do
        sandbox.start_program([RbConfig.ruby, "-e", "exit"], allow_subprocesses: true)
      end

      assert_includes error.message, "cannot safely own subprocess descendants"
      refute sandbox.supports?(:process_spawn)
    ensure
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
