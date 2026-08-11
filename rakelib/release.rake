# frozen_string_literal: true

require "rbconfig"
require "open3"
require_relative "little_ghost_release"

namespace :package do
  desc "Build and verify the gem package"
  task check: :build do
    path = File.expand_path("pkg/little_ghost-#{LittleGhost::VERSION}.gem", __dir__ + "/..")
    LittleGhostRelease.verify_package!(path, LittleGhost::VERSION)

    Dir.mktmpdir("little-ghost-install") do |directory|
      LittleGhostRelease.extract(path, directory)
      ruby = RbConfig.ruby
      command = [ruby, "-I#{File.join(directory, "lib")}", "-e", "require 'little_ghost'; abort unless LittleGhost::VERSION == '#{LittleGhost::VERSION}'"]
      loaded = Bundler.with_unbundled_env { system({"RUBYOPT" => nil, "RUBYLIB" => nil}, *command) }
      abort "Built gem could not be loaded" unless loaded
    end

    puts "Verified #{File.basename(path)} contents and loading behavior."
  end
end

namespace :release do
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
    puts "Verified published gem matches #{local_path}."
  end
end
