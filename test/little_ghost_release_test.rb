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

  def test_current_gem_package_has_the_release_contract
    Dir.mktmpdir("little-ghost-release-test") do |directory|
      path = File.join(directory, "little_ghost-#{LittleGhost::VERSION}.gem")
      specification = Gem::Specification.load(File.expand_path("../little_ghost.gemspec", __dir__))

      Dir.chdir(File.expand_path("..", __dir__)) do
        Gem::Package.build(specification, true, false, path)
      end

      manifest = LittleGhostRelease.verify_package!(path, LittleGhost::VERSION)

      assert_equal "little_ghost", manifest.fetch(:name)
      assert_includes manifest.fetch(:files), "lib/little_ghost/default_model_registry.rb"
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
