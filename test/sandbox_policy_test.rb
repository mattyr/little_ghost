# frozen_string_literal: true

require "test_helper"

class SandboxPolicyTest < Minitest::Test
  def test_generic_sandbox_probe_handles_providers_without_a_custom_probe
    provider_name = :sandbox_policy_test_provider
    LittleGhost::Sandbox.register_provider(provider_name, Class.new(LittleGhost::Sandbox))

    unrestricted = LittleGhost::Sandbox.probe(:unrestricted)
    custom = LittleGhost::Sandbox.probe(provider_name)

    assert unrestricted.fetch(:available)
    assert custom.fetch(:available)
    assert LittleGhost::Sandboxes::Unrestricted.probe(:unrestricted).fetch(:available)
    assert_raises(ArgumentError) do
      LittleGhost::Sandbox.probe(:unrestricted, unknown_option: true)
    end
  end

  def test_sandbox_backends_reject_removed_and_unknown_options
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:)

      assert_raises(ArgumentError) do
        LittleGhost::Sandboxes::Unrestricted.new(workspace:, writable: true)
      end
      assert_raises(ArgumentError) do
        LittleGhost::Sandboxes::Bubblewrap.new(workspace:, unknown_option: true)
      end
      assert_raises(ArgumentError) do
        LittleGhost::Sandboxes::Docker.new(workspace:, image: "ruby:latest", unknown_option: true)
      end

      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:)
      assert_raises(ArgumentError) do
        sandbox.execute_program([RbConfig.ruby, "-e", "exit"], timeout: 1, unknown_option: true)
      end
    end
  end

  def test_unrestricted_process_cannot_widen_environment_inheritance
    Dir.mktmpdir do |root|
      previous = ENV["LITTLE_GHOST_POLICY_SECRET"]
      ENV["LITTLE_GHOST_POLICY_SECRET"] = "credential"
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {environment: {inherit: false}, network: :inherit}
      )

      result = sandbox.execute_program(
        [RbConfig.ruby, "-e", "print ENV['LITTLE_GHOST_POLICY_SECRET'].to_s"],
        timeout: 1,
        inherit_environment: true
      )

      assert_equal "", result.stdout
    ensure
      ENV["LITTLE_GHOST_POLICY_SECRET"] = previous
    end
  end

  def test_policy_normalizes_mount_environment_network_and_lifecycle
    Dir.mktmpdir do |root|
      policy = LittleGhost::Sandbox::Policy.new(
        workspace_path: "/work",
        workspace_access: :read_write,
        mounts: [{source: "skills", target: "/skills"}],
        environment: {inherit: true, set: {"MODE" => :test}},
        network: {mode: :allowlist, allow: ["EXAMPLE.COM:443"]},
        execution_scope: :sandbox,
        root:
      )

      assert_equal "/work", policy.workspace_path
      assert policy.workspace_writable?
      assert_equal File.join(root, "skills"), policy.mounts.first.source
      assert policy.environment.inherit?
      assert_equal({"MODE" => "test"}, policy.environment.values)
      assert_equal ["example.com:443"], policy.network.allow
      assert policy.sandbox_scoped?
      assert policy.frozen?
    end
  end

  def test_sandbox_limits_are_configurable_and_enforced_by_scopes
    Dir.mktmpdir do |root|
      File.write(File.join(root, "large.txt"), "a" * 1_000_001)
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        limits: {read_bytes: 1_000_001, write_bytes: 2_000_000, output_bytes: 3_000_000}
      )

      assert_equal 1_000_001, sandbox.read("large.txt").bytesize
      assert_equal 2_000_000, sandbox.limits.write_bytes
      assert_equal 3_000_000, sandbox.limits.output_bytes
    end
  end

  def test_process_only_mounts_are_not_exposed_to_filesystem_tools
    Dir.mktmpdir do |root|
      private_root = File.join(root, "private")
      FileUtils.mkdir_p(private_root)
      File.write(File.join(private_root, "secret.txt"), "secret")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {
          mounts: [{source: private_root, target: "/private", tools: false}],
          network: :inherit
        }
      )
      scope = sandbox.scope

      assert scope.mounts.any? { |mount| mount.target == "/private" }
      refute scope.allows?(:filesystem_read, "/private/secret.txt")
      assert_raises(LittleGhost::ToolError) { scope.read("/private/secret.txt") }
      refute scope.allows?(:filesystem_read, "/workspace/private/secret.txt")
      assert_raises(LittleGhost::ToolError) { scope.read("/workspace/private/secret.txt") }

      nested = scope.scope(mounts: ["/workspace"])
      refute nested.mounts.any? { |mount| mount.target == "/private" }
      refute nested.allows?(:filesystem_read, "/workspace/private/secret.txt")
      assert_raises(LittleGhost::ToolError) { nested.read("/workspace/private/secret.txt") }
    end
  end

  def test_narrow_visible_mount_does_not_retain_its_process_only_physical_parent
    Dir.mktmpdir do |root|
      home = Dir.mktmpdir
      scratch = File.join(home, "scratch")
      FileUtils.mkdir_p(scratch)
      File.write(File.join(scratch, "visible.txt"), "visible")
      File.write(File.join(home, "secret.txt"), "secret")
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {
          mounts: [
            {source: home, target: "/home", access: :read_write, tools: false},
            {source: scratch, target: "/scratch", access: :read_write}
          ],
          network: :inherit
        }
      )

      scope = sandbox.scope.scope(mounts: ["/scratch"])

      assert_equal ["/scratch"], scope.mounts.map(&:target)
      assert_equal "visible", scope.read("/scratch/visible.txt")
      assert_raises(LittleGhost::ToolError) { scope.read("/home/secret.txt") }
    ensure
      FileUtils.remove_entry(home) if home && File.exist?(home)
    end
  end

  def test_policy_rejects_duplicate_and_traversing_mount_targets
    error = assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::Mount.new(source: ".", target: "/workspace/../secret")
    end
    assert_match(/traversal/, error.message)

    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::Policy.new(
        mounts: [
          {source: ".", target: "/skills"},
          {source: ".", target: "/skills"}
        ]
      )
    end
  end

  def test_network_options_are_only_valid_for_an_allowlist
    error = assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::NetworkPolicy.new(mode: :none, allow: ["example.com:443"])
    end

    assert_match(/require mode :allowlist/, error.message)

    assert_raises(LittleGhost::PolicyError) do
      LittleGhost::Sandbox::NetworkPolicy.new(mode: :allowlist)
    end
  end

  def test_capabilities_intersect_without_widening
    parent = LittleGhost::Sandbox::Capabilities.new(
      features: %i[filesystem_read filesystem_write process_execute],
      network_modes: %i[none allowlist],
      isolation: :process
    )
    child = LittleGhost::Sandbox::Capabilities.new(
      features: %i[filesystem_read process_execute process_spawn],
      network_modes: %i[inherit none]
    )

    result = parent.intersect(child)

    assert result.supports?(:filesystem_read)
    assert result.supports?(:read)
    assert result.supports?(:process_execute)
    refute result.supports?(:filesystem_write)
    refute result.supports?(:process_spawn)
    assert result.supports?(:network, :none)
    refute result.supports?(:network, :inherit)
  end

  def test_scope_narrows_mounts_capabilities_and_write_access
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "private"))
      File.write(File.join(root, "visible.txt"), "visible")
      File.write(File.join(root, "private", "secret.txt"), "secret")
      workspace = LittleGhost::Workspace.new(root:)
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace:,
        policy: {workspace_access: :read_write, network: :inherit}
      )
      scope = sandbox.scope(
        mounts: [{target: "/workspace/private", access: :read_only}],
        capabilities: LittleGhost::Sandbox::Capabilities.new(
          features: %i[filesystem_read filesystem_list filesystem_write filesystem_replace process_execute]
        )
      )

      assert_equal "secret", scope.read("private/secret.txt")
      refute scope.allows?(:filesystem_write, "private/secret.txt")
      assert_raises(LittleGhost::ToolError) { scope.read("visible.txt") }
      assert_raises(LittleGhost::ToolError) { scope.write("private/new.txt", "no") }

      nested = scope.scope(mounts: ["/workspace/private"])
      assert_equal "secret", nested.read("private/secret.txt")
      assert_raises(LittleGhost::CapabilityError) do
        scope.scope(mounts: ["/workspace"])
      end
    end
  end

  def test_named_scope_profiles_can_disable_but_not_widen_network_access
    Dir.mktmpdir do |root|
      sandbox = LittleGhost::Sandboxes::Bubblewrap.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {
          network: {mode: :allowlist, allow: ["example.com:443"]}
        },
        profiles: {
          connected: {network: true},
          offline: {network: false}
        }
      )

      assert sandbox.scope(:connected).network.allowlist?
      assert sandbox.scope(:offline).network.none?
      assert sandbox.scope(:connected).supports?(:network, :allowlist)
      refute sandbox.scope(:connected).supports?(:network, :none)
      assert sandbox.scope(:offline).supports?(:network, :none)
      refute sandbox.scope(:offline).supports?(:network, :allowlist)
      assert_raises(LittleGhost::PolicyError) { sandbox.scope(:missing) }
      assert_raises(LittleGhost::CapabilityError) do
        sandbox.scope(:offline).scope(network: :inherit)
      end
    end
  end

  def test_scope_rejects_a_symlinked_child_that_escapes_its_parent
    Dir.mktmpdir do |root|
      outside = Dir.mktmpdir
      File.symlink(outside, File.join(root, "escape"))
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {workspace_access: :read_write, network: :inherit}
      )

      error = assert_raises(LittleGhost::CapabilityError) do
        sandbox.scope(mounts: ["/workspace/escape"])
      end

      assert_match(/escapes its parent/, error.message)
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def test_nested_scope_preserves_a_restrictive_descendant_overlay
    Dir.mktmpdir do |root|
      attachments = File.join(root, "attachments")
      FileUtils.mkdir_p(attachments)
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {
          workspace_access: :read_write,
          mounts: [{source: attachments, target: "/workspace/attachments", access: :read_only}],
          network: :inherit
        }
      )

      nested = sandbox.scope.scope(mounts: ["/workspace"])

      assert nested.mounts.any? { |mount| mount.target == "/workspace/attachments" && mount.read_only? }
      assert_raises(LittleGhost::ToolError) do
        nested.write("/workspace/attachments/new.txt", "no")
      end
    end
  end

  def test_protected_mount_permissions_apply_through_physical_aliases
    Dir.mktmpdir do |root|
      protected_root = File.join(root, "attachments")
      FileUtils.mkdir_p(protected_root)
      File.write(File.join(protected_root, "report.txt"), "report")
      File.symlink("attachments", File.join(root, "alias"))
      workspace = LittleGhost::Workspace.new(root:)
      policy = LittleGhost::Sandbox::Policy.new(
        workspace_access: :read_write,
        mounts: [
          {
            source: protected_root,
            target: "/attachments",
            access: :read_only,
            protect_aliases: true
          }
        ]
      )
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(workspace:, policy:)
      scope = sandbox.scope

      assert_equal "report", scope.read("/workspace/attachments/report.txt")
      refute scope.allows?(:filesystem_write, "/workspace/alias/report.txt")
      refute scope.allows?(:filesystem_write, "/workspace/attachments/report.txt")
      assert_raises(LittleGhost::ToolError) do
        scope.write("/workspace/attachments/report.txt", "changed")
      end

      nested = scope.scope(mounts: ["/workspace"])
      assert nested.mounts.any? { |mount| mount.target == "/attachments" && mount.read_only? }
      assert_raises(LittleGhost::ToolError) do
        nested.write("/workspace/attachments/new.txt", "changed")
      end
    end
  end

  def test_unrestricted_sandbox_exposes_configured_mounts_to_direct_file_tools
    Dir.mktmpdir do |root|
      skills = Dir.mktmpdir
      File.write(File.join(skills, "guide.md"), "guide")
      policy = LittleGhost::Sandbox::Policy.new(
        mounts: [{source: skills, target: "/skills"}],
        network: :inherit
      )
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy:
      )

      assert_equal "guide", sandbox.read("/skills/guide.md")
      assert_raises(LittleGhost::ToolError) do
        sandbox.write("/skills/new.md", "no")
      end
    ensure
      FileUtils.remove_entry(skills) if skills && File.exist?(skills)
    end
  end

  def test_unrestricted_sandbox_coerces_hash_policy_and_writable_extra_mounts
    Dir.mktmpdir do |root|
      shared = Dir.mktmpdir
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:),
        policy: {
          workspace_access: :read_only,
          mounts: [{source: shared, target: "/shared", access: :read_write}],
          network: :inherit
        }
      )

      assert sandbox.writable?
      assert sandbox.supports?(:filesystem_write)
      assert_equal "Wrote 2 bytes to /shared/note.txt", sandbox.write("/shared/note.txt", "ok")
      assert_equal "ok", File.read(File.join(shared, "note.txt"))
    ensure
      FileUtils.remove_entry(shared) if shared && File.exist?(shared)
    end
  end

  def test_unrestricted_rejects_network_guarantees_it_cannot_enforce
    Dir.mktmpdir do |root|
      workspace = LittleGhost::Workspace.new(root:)
      policy = LittleGhost::Sandbox::Policy.new(network: :none)

      error = assert_raises(LittleGhost::CapabilityError) do
        LittleGhost::Sandboxes::Unrestricted.new(workspace:, policy:)
      end

      assert_match(/cannot enforce network mode :none/, error.message)
    end
  end

  def test_unrestricted_scope_cannot_claim_network_isolation
    Dir.mktmpdir do |root|
      sandbox = LittleGhost::Sandboxes::Unrestricted.new(
        workspace: LittleGhost::Workspace.new(root:)
      )

      error = assert_raises(LittleGhost::CapabilityError) do
        sandbox.scope(network: false)
      end

      assert_match(/cannot enforce scoped network mode :none/, error.message)
    end
  end

  def test_probe_reports_an_unavailable_provider_without_falling_back
    result = LittleGhost::Sandbox.probe(:missing)

    refute result.fetch(:available)
    assert_match(/provider :missing is not available/, result.fetch(:reason))
    refute result.fetch(:capabilities).supports?(:process_execute)
  end
end
