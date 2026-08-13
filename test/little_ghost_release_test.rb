# frozen_string_literal: true

require "test_helper"
require_relative "../rakelib/little_ghost_release"

class LittleGhostReleaseTest < Minitest::Test
  def test_expected_tag_uses_the_gem_version
    assert_equal "v1.2.3", LittleGhostRelease.expected_tag(Gem::Version.new("1.2.3"))
    assert_equal "v1.2.3.pre", LittleGhostRelease.expected_tag(Gem::Version.new("1.2.3.pre"))
  end

  def test_verify_tag_accepts_only_the_exact_version
    assert_equal "v1.2.3", LittleGhostRelease.verify_tag!("v1.2.3", "1.2.3")

    {
      "v1.2.4" => 'Release tag must be v1.2.3, got "v1.2.4"',
      "1.2.3" => 'Release tag must be v1.2.3, got "1.2.3"',
      "v1.2.3.pre" => 'Release tag must be v1.2.3, got "v1.2.3.pre"'
    }.each do |tag, message|
      error = assert_raises(LittleGhostRelease::Error) do
        LittleGhostRelease.verify_tag!(tag, "1.2.3")
      end
      assert_equal message, error.message
    end
  end

  def test_release_signing_key_must_be_registered_with_the_authenticated_github_user
    runner = command_runner(
      [["git", "config", "--get", "user.signingkey"], ["ssh-ed25519 local-key comment\n", true]],
      [["gh", "api", "user", "--jq", ".login"], ["octocat\n", true]],
      [
        ["gh", "api", "users/octocat/ssh_signing_keys", "--paginate", "--jq", ".[].key"],
        ["ssh-ed25519 another-key\nssh-ed25519 local-key\n", true]
      ]
    )

    assert_equal "ssh-ed25519 local-key", LittleGhostRelease.verify_release_signing_key!(command_runner: runner)
  end

  def test_release_signing_key_accepts_a_public_key_file
    Dir.mktmpdir("little-ghost-signing-key") do |directory|
      path = File.join(directory, "release.pub")
      File.write(path, "ssh-ed25519 file-key comment\n")
      runner = command_runner(
        [["git", "config", "--get", "user.signingkey"], ["#{path}\n", true]],
        [["gh", "api", "user", "--jq", ".login"], ["octocat\n", true]],
        [
          ["gh", "api", "users/octocat/ssh_signing_keys", "--paginate", "--jq", ".[].key"],
          ["ssh-ed25519 file-key\n", true]
        ]
      )

      assert_equal "ssh-ed25519 file-key", LittleGhostRelease.verify_release_signing_key!(command_runner: runner)
    end
  end

  def test_release_signing_key_accepts_git_literal_key_syntax
    runner = command_runner(
      [["git", "config", "--get", "user.signingkey"], ["key::ssh-ed25519 literal-key comment\n", true]],
      [["gh", "api", "user", "--jq", ".login"], ["octocat\n", true]],
      [
        ["gh", "api", "users/octocat/ssh_signing_keys", "--paginate", "--jq", ".[].key"],
        ["ssh-ed25519 literal-key\n", true]
      ]
    )

    assert_equal "ssh-ed25519 literal-key", LittleGhostRelease.verify_release_signing_key!(command_runner: runner)
  end

  def test_release_signing_key_rejects_an_oversized_public_key_file
    Dir.mktmpdir("little-ghost-signing-key") do |directory|
      path = File.join(directory, "release.pub")
      File.write(path, "ssh-ed25519 #{"a" * (16 * 1024)}")
      runner = command_runner(
        [["git", "config", "--get", "user.signingkey"], ["#{path}\n", true]]
      )

      error = assert_raises(LittleGhostRelease::Error) do
        LittleGhostRelease.verify_release_signing_key!(command_runner: runner)
      end
      assert_equal "Configure user.signingkey as an SSH public key registered with GitHub for signing", error.message
    end
  end

  def test_release_signing_key_rejects_missing_or_unregistered_keys
    missing_key = command_runner(
      [["git", "config", "--get", "user.signingkey"], ["", false]]
    )
    error = assert_raises(LittleGhostRelease::Error) do
      LittleGhostRelease.verify_release_signing_key!(command_runner: missing_key)
    end
    assert_equal "Configure user.signingkey as an SSH public key registered with GitHub for signing", error.message

    unregistered_key = command_runner(
      [["git", "config", "--get", "user.signingkey"], ["ssh-ed25519 local-key\n", true]],
      [["gh", "api", "user", "--jq", ".login"], ["octocat\n", true]],
      [
        ["gh", "api", "users/octocat/ssh_signing_keys", "--paginate", "--jq", ".[].key"],
        ["ssh-ed25519 another-key\n", true]
      ]
    )
    error = assert_raises(LittleGhostRelease::Error) do
      LittleGhostRelease.verify_release_signing_key!(command_runner: unregistered_key)
    end
    assert_equal "user.signingkey is not registered as a GitHub SSH signing key for octocat", error.message
  end

  def test_create_signed_tag_forces_ssh_signing
    command = nil
    runner = lambda do |*arguments|
      command = arguments
      true
    end

    assert_equal "v1.2.3", LittleGhostRelease.create_signed_tag!("v1.2.3", "1.2.3", command_runner: runner)
    assert_equal ["git", "-c", "gpg.format=ssh", "tag", "-s", "v1.2.3", "-m", "Version 1.2.3"], command
  end

  def test_create_signed_tag_fails_when_git_cannot_sign
    error = assert_raises(LittleGhostRelease::Error) do
      LittleGhostRelease.create_signed_tag!("v1.2.3", "1.2.3", command_runner: ->(*) { false })
    end

    assert_equal "Could not create signed release tag v1.2.3", error.message
  end

  def test_release_workflow_prepares_checks_labels_and_merges_the_version_pull_request
    captures = capture_runner(
      [["git", "branch", "--show-current"], ["main\n", true]],
      [["git", "status", "--porcelain"], ["", true]],
      [["git", "remote", "get-url", "origin"], ["git@github.com:mattyr/little_ghost.git\n", true]],
      [["git", "rev-parse", "HEAD"], ["commit\n", true]],
      [["git", "rev-parse", "origin/main"], ["commit\n", true]],
      [["git", "rev-parse", "HEAD"], ["release-head\n", true]],
      [
        lambda do |arguments|
          next false unless arguments.take(3) == ["gh", "pr", "create"]

          body_path = arguments.fetch(arguments.index("--body-file") + 1)
          assert_includes File.read(body_path), "prepare LittleGhost 1.2.3 for release"
          true
        end,
        ["https://github.com/mattyr/little_ghost/pull/123\n", true]
      ],
      [
        [
          "gh", "pr", "view", "123", "--repo", "mattyr/little_ghost",
          "--json", "statusCheckRollup", "--jq", ".statusCheckRollup | length"
        ],
        ["3\n", true]
      ],
      [
        [
          "gh", "pr", "view", "123", "--repo", "mattyr/little_ghost",
          "--json", "state,headRefOid,files", "--jq", '[.state,.headRefOid,([.files[].path] | sort | join(","))] | @tsv'
        ],
        ["OPEN\trelease-head\tGemfile.lock,lib/little_ghost/version.rb,test/little_ghost_test.rb\n", true]
      ],
      [
        [
          "gh", "pr", "view", "123", "--repo", "mattyr/little_ghost",
          "--json", "state,headRefOid,files", "--jq", '[.state,.headRefOid,([.files[].path] | sort | join(","))] | @tsv'
        ],
        ["MERGED\trelease-head\tGemfile.lock,lib/little_ghost/version.rb,test/little_ghost_test.rb\n", true]
      ]
    )
    commands = []
    runner = ->(*command) { commands << command }

    LittleGhostRelease::Workflow.new(command_runner: runner, capture_runner: captures).prepare_pull_request("1.2.3")

    assert_includes commands, ["git", "switch", "-c", "release-1.2.3"]
    assert_includes commands, ["bundle", "exec", "rake", "release:prepare[1.2.3]"]
    assert_includes commands, ["gh", "pr", "checks", "123", "--repo", "mattyr/little_ghost", "--watch", "--interval", "10"]
    assert_includes commands, [
      "gh", "pr", "merge", "123", "--repo", "mattyr/little_ghost",
      "--squash", "--match-head-commit", "release-head"
    ]
    assert_equal ["git", "branch", "-D", "release-1.2.3"], commands.last
  end

  def test_release_workflow_rejects_preparation_outside_main
    captures = capture_runner(
      [["git", "branch", "--show-current"], ["feature\n", true]]
    )
    error = assert_raises(LittleGhostRelease::Error) do
      LittleGhostRelease::Workflow.new(command_runner: ->(*) { flunk }, capture_runner: captures)
        .prepare_pull_request("1.2.3")
    end

    assert_equal 'Release workflow must start on main, got "feature"', error.message
  end

  def test_release_workflow_publishes_the_signed_tag_and_watches_github
    captures = capture_runner(
      [["git", "branch", "--show-current"], ["main\n", true]],
      [["git", "status", "--porcelain"], ["", true]],
      [["git", "remote", "get-url", "origin"], ["https://github.com/mattyr/little_ghost.git\n", true]],
      [["git", "rev-parse", "HEAD"], ["commit\n", true]],
      [["git", "rev-parse", "origin/main"], ["commit\n", true]],
      [["git", "rev-parse", "--verify", "refs/tags/v1.2.3"], ["", false]],
      [["git", "ls-remote", "--tags", "origin", "refs/tags/v1.2.3"], ["", true]],
      [["git", "rev-parse", "refs/tags/v1.2.3"], ["tag-object\n", true]],
      [["git", "rev-parse", "refs/tags/v1.2.3^{commit}"], ["commit\n", true]],
      [
        [
          "gh", "api", "repos/mattyr/little_ghost/git/tags/tag-object",
          "--jq", "[.verification.verified,.object.type,.object.sha] | @tsv"
        ],
        ["true\tcommit\tcommit\n", true]
      ],
      [
        [
          "gh", "run", "list", "--repo", "mattyr/little_ghost", "--workflow", "release.yml",
          "--branch", "v1.2.3", "--event", "push", "--limit", "10", "--json", "databaseId,headSha"
        ],
        [JSON.generate([{"databaseId" => 12345, "headSha" => "commit"}]), true]
      ]
    )
    commands = []

    LittleGhostRelease::Workflow.new(
      command_runner: ->(*command) { commands << command },
      capture_runner: captures
    ).publish("1.2.3")

    assert_equal [
      ["git", "fetch", "origin", "main", "--tags"],
      ["bundle", "exec", "rake", "release:tag"],
      ["git", "push", "origin", "v1.2.3"],
      ["gh", "run", "watch", "12345", "--repo", "mattyr/little_ghost", "--exit-status"]
    ], commands
  end

  def test_release_workflow_resumes_an_existing_verified_tag
    captures = capture_runner(
      [["git", "branch", "--show-current"], ["main\n", true]],
      [["git", "status", "--porcelain"], ["", true]],
      [["git", "remote", "get-url", "origin"], ["git@github.com:mattyr/little_ghost.git\n", true]],
      [["git", "rev-parse", "HEAD"], ["commit\n", true]],
      [["git", "rev-parse", "origin/main"], ["commit\n", true]],
      [["git", "rev-parse", "--verify", "refs/tags/v1.2.3"], ["tag-object\n", true]],
      [["git", "ls-remote", "--tags", "origin", "refs/tags/v1.2.3"], ["tag-object\trefs/tags/v1.2.3\n", true]],
      [["git", "cat-file", "-t", "refs/tags/v1.2.3"], ["tag\n", true]],
      [["git", "rev-parse", "refs/tags/v1.2.3^{commit}"], ["commit\n", true]],
      [["git", "rev-parse", "HEAD"], ["commit\n", true]],
      [
        [
          "gh", "api", "repos/mattyr/little_ghost/git/tags/tag-object",
          "--jq", "[.verification.verified,.object.type,.object.sha] | @tsv"
        ],
        ["true\tcommit\tcommit\n", true]
      ],
      [
        [
          "gh", "run", "list", "--repo", "mattyr/little_ghost", "--workflow", "release.yml",
          "--branch", "v1.2.3", "--event", "push", "--limit", "10", "--json", "databaseId,headSha"
        ],
        [JSON.generate([{"databaseId" => 12345, "headSha" => "commit"}]), true]
      ]
    )
    commands = []

    LittleGhostRelease::Workflow.new(
      command_runner: ->(*command) { commands << command },
      capture_runner: captures
    ).publish("1.2.3")

    refute_includes commands, ["bundle", "exec", "rake", "release:tag"]
    refute_includes commands, ["git", "push", "origin", "v1.2.3"]
    assert_equal ["gh", "run", "watch", "12345", "--repo", "mattyr/little_ghost", "--exit-status"], commands.last
  end

  def test_current_gem_package_has_the_release_contract
    Dir.mktmpdir("little-ghost-release-test") do |directory|
      path = File.join(directory, "little_ghost-#{LittleGhost::VERSION}.gem")
      specification = Gem::Specification.load(File.expand_path("../little_ghost.gemspec", __dir__))

      Dir.chdir(File.expand_path("..", __dir__)) do
        Gem::Package.build(specification, true, false, path)
      end

      manifest = LittleGhostRelease.verify_package!(path, LittleGhost::VERSION)

      assert_equal "little_ghost", manifest.fetch(:name)
      assert_includes manifest.fetch(:files), "lib/little_ghost/model_resolver.rb"
      assert_includes manifest.fetch(:files), "lib/little_ghost/data/model_catalog.json"
      refute_includes manifest.fetch(:files), "lib/little_ghost/model_registry.rb"
      refute manifest.fetch(:files).any? { |file| file.start_with?("test/") }
    end
  end

  def test_published_package_comparison_uses_specification_and_file_contents
    Dir.mktmpdir("little-ghost-release-test") do |directory|
      local = build_test_gem(directory, "local.gem", content: "same")
      matching = build_test_gem(directory, "matching.gem", content: "same")
      different = build_test_gem(directory, "different.gem", content: "different")

      assert LittleGhostRelease.verify_published_package!(local, matching)
      assert_raises(LittleGhostRelease::Error) do
        LittleGhostRelease.verify_published_package!(local, different)
      end
    end
  end

  def test_published_package_comparison_rejects_an_undeclared_archive_entry
    Dir.mktmpdir("little-ghost-release-test") do |directory|
      local = build_test_gem(directory, "local.gem", content: "same")
      published = build_test_gem(directory, "published.gem", content: "same", package_class: PackageWithUndeclaredFile)

      error = assert_raises(LittleGhostRelease::Error) do
        LittleGhostRelease.verify_published_package!(local, published)
      end
      assert_equal "Published gem does not match the package built from this tag", error.message
    end
  end

  def test_published_package_comparison_rejects_a_required_rubygems_version_change
    Dir.mktmpdir("little-ghost-release-test") do |directory|
      local = build_test_gem(directory, "local.gem", content: "same", required_rubygems_version: ">= 0")
      published = build_test_gem(directory, "published.gem", content: "same", required_rubygems_version: ">= 99")

      assert_raises(LittleGhostRelease::Error) do
        LittleGhostRelease.verify_published_package!(local, published)
      end
    end
  end

  private

  def command_runner(*expectations)
    lambda do |*arguments|
      expected_arguments, (output, success) = expectations.shift
      if expected_arguments.respond_to?(:call)
        assert expected_arguments.call(arguments), "Unexpected command: #{arguments.inspect}"
      else
        assert_equal expected_arguments, arguments
      end
      status = Object.new
      status.define_singleton_method(:success?) { success }
      [output, status]
    ensure
      assert_empty expectations if expectations.empty?
    end
  end

  def capture_runner(*expectations)
    lambda do |*arguments|
      expected_arguments, result = expectations.shift
      if expected_arguments.respond_to?(:call)
        assert expected_arguments.call(arguments), "Unexpected command: #{arguments.inspect}"
      else
        assert_equal expected_arguments, arguments
      end
      result.then do |output, success|
        status = Object.new
        status.define_singleton_method(:success?) { success }
        [output, status]
      end
    ensure
      assert_empty expectations if expectations.empty?
    end
  end

  class PackageWithUndeclaredFile < Gem::Package
    def add_files(tar)
      super
      payload = "raise 'undeclared payload loaded'\n"
      tar.add_file_simple("lib/base64.rb", 0o644, payload.bytesize) { |io| io.write(payload) }
    end
  end

  def build_test_gem(directory, file_name, content:, package_class: Gem::Package, required_rubygems_version: ">= 0")
    source = File.join(directory, "fixture.rb")
    File.write(source, content)
    specification = Gem::Specification.new do |spec|
      spec.name = "release_fixture"
      spec.version = "1.0.0"
      spec.summary = "Release fixture"
      spec.authors = ["LittleGhost"]
      spec.files = ["fixture.rb"]
      spec.required_rubygems_version = required_rubygems_version
    end
    path = File.join(directory, file_name)

    Dir.chdir(directory) { package_class.build(specification, true, false, path) }
    path
  end
end
