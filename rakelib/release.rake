# frozen_string_literal: true

require "rbconfig"
require "open3"
require_relative "little_ghost_release"

RELEASE_VERSION_FILE = File.expand_path("../lib/little_ghost/version.rb", __dir__)
RELEASE_VERSION_TEST = File.expand_path("../test/little_ghost_test.rb", __dir__)
RELEASE_LOCKFILE = File.expand_path("../Gemfile.lock", __dir__)

namespace :package do
  desc "Build and verify the gem package"
  task check: :build do
    path = File.expand_path("pkg/little_ghost-#{LittleGhost::VERSION}.gem", __dir__ + "/..")
    LittleGhostRelease.verify_package!(path, LittleGhost::VERSION)

    Dir.mktmpdir("little-ghost-install") do |directory|
      LittleGhostRelease.extract(path, directory)
      ruby = RbConfig.ruby
      program = "LittleGhost.send(:remove_const, :VERSION) if defined?(LittleGhost::VERSION); require 'little_ghost'; abort unless LittleGhost::VERSION == '#{LittleGhost::VERSION}'"
      command = [ruby, "-I#{File.join(directory, "lib")}", "-e", program]
      loaded = system(*command)
      abort "Built gem could not be loaded" unless loaded
    end

    puts "Verified #{File.basename(path)} contents and loading behavior."
  end
end

namespace :release do
  desc "Prepare a version bump and update its derived files"
  task :prepare, [:version] do |_, arguments|
    version = arguments[:version]
    abort 'Usage: bundle exec rake "release:prepare[VERSION]"' unless version
    unless Gem::Version.correct?(version) && version.match?(/\A\d[0-9A-Za-z.-]*\z/)
      abort "Release version must be a valid RubyGems version, got #{version.inspect}"
    end
    status, status_result = Open3.capture2e("git", "status", "--porcelain")
    abort "Could not inspect the worktree" unless status_result.success?
    abort "Release preparation requires a clean worktree" unless status.empty?

    originals = [RELEASE_VERSION_FILE, RELEASE_VERSION_TEST, RELEASE_LOCKFILE].to_h { |path| [path, File.binread(path)] }
    current = LittleGhost::VERSION
    abort "LittleGhost is already version #{version}" if version == current
    abort "Release version must be newer than #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)

    version_file = originals.fetch(RELEASE_VERSION_FILE).sub(%(VERSION = "#{current}"), %(VERSION = "#{version}"))
    version_test = originals.fetch(RELEASE_VERSION_TEST).sub(%(assert_equal "#{current}", LittleGhost::VERSION), %(assert_equal "#{version}", LittleGhost::VERSION))
    abort "Could not find #{current} in #{RELEASE_VERSION_FILE}" if version_file == originals.fetch(RELEASE_VERSION_FILE)
    abort "Could not find #{current} in #{RELEASE_VERSION_TEST}" if version_test == originals.fetch(RELEASE_VERSION_TEST)

    begin
      File.write(RELEASE_VERSION_FILE, version_file)
      File.write(RELEASE_VERSION_TEST, version_test)
      unless system("bundle", "lock")
        originals.each { |path, content| File.binwrite(path, content) }
        abort "Could not update Gemfile.lock; restored release files"
      end
    rescue
      originals.each { |path, content| File.binwrite(path, content) }
      raise
    end

    puts "Prepared LittleGhost #{version}. Run the release gate and open a pull request."
  end

  desc "Check whether HEAD is ready to receive its version tag"
  task :doctor do
    version = LittleGhost::VERSION
    tag = LittleGhostRelease.expected_tag(version)
    status, status_result = Open3.capture2e("git", "status", "--porcelain")
    abort "Could not inspect the worktree" unless status_result.success?
    abort "Release doctor requires a clean worktree" unless status.empty?

    head, head_status = Open3.capture2e("git", "rev-parse", "HEAD")
    main, main_status = Open3.capture2e("git", "rev-parse", "origin/main")
    abort "Fetch origin/main before running release:doctor" unless head_status.success? && main_status.success?
    abort "HEAD must exactly match origin/main before tagging" unless head == main
    abort "Tag #{tag} already exists locally" if system("git", "rev-parse", "--verify", "--quiet", "refs/tags/#{tag}")

    remote_tag, remote_status = Open3.capture2e("git", "ls-remote", "--exit-code", "--tags", "origin", "refs/tags/#{tag}")
    abort "Could not check origin for #{tag}" unless remote_status.success? || remote_status.exitstatus == 2
    abort "Tag #{tag} already exists on origin" unless remote_tag.empty?
    abort "little_ghost #{version} already exists on RubyGems" if LittleGhostRelease.published_version?(version)

    puts "Verified #{tag} can be created from origin/main and published to RubyGems."
  end

  desc "Verify the release tag and its main-branch ancestry"
  task :verify do
    tag = ENV.fetch("RELEASE_TAG", ENV["GITHUB_REF_NAME"])
    LittleGhostRelease.verify_tag!(tag, LittleGhost::VERSION)

    tag_revision, tag_status = Open3.capture2e("git", "rev-parse", "--verify", "refs/tags/#{tag}^{commit}")
    head_revision, head_status = Open3.capture2e("git", "rev-parse", "HEAD")
    abort "Release tag #{tag} must exist and point to HEAD" unless tag_status.success? && head_status.success? && tag_revision == head_revision

    main_ref = ENV.fetch("RELEASE_MAIN_REF", "origin/main")
    unless system("git", "merge-base", "--is-ancestor", "HEAD", main_ref, out: File::NULL)
      abort "Release commit must belong to #{main_ref}"
    end

    puts "Verified #{tag} at a commit contained in #{main_ref}."
  end

  desc "Verify a downloaded RubyGems package against the package built from this tag"
  task :verify_published, [:published_path] => "package:check" do |_, arguments|
    published_path = arguments.fetch(:published_path)
    local_path = "pkg/little_ghost-#{LittleGhost::VERSION}.gem"
    LittleGhostRelease.verify_published_package!(local_path, published_path)
    checksum = LittleGhostRelease.verify_rubygems_checksum!(LittleGhost::VERSION, published_path)
    File.write("#{published_path}.sha256", "#{checksum}  #{File.basename(published_path)}\n")
    puts "Verified published gem matches #{local_path}."
  end
end
