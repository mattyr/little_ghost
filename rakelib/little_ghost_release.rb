# frozen_string_literal: true

require "digest"
require "rubygems/package"
require "tmpdir"
require "yaml"
require "zlib"

module LittleGhostRelease
  class Error < StandardError; end

  REQUIRED_FILES = %w[
    LICENSE.txt
    README.md
    docs/guides/Core\ Concepts.md
    docs/guides/Getting\ Started.md
    lib/little_ghost.rb
    lib/little_ghost/version.rb
  ].freeze
  EXCLUDED_PATHS = %r{\A(?:\.github|site|test|rakelib|pkg)/}
  REQUIRED_METADATA = {
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }.freeze

  module_function

  def expected_tag(version)
    "v#{version}"
  end

  def verify_tag!(tag, version)
    expected = expected_tag(version)
    raise Error, "Release tag must be #{expected}, got #{tag.inspect}" unless tag == expected

    expected
  end

  def manifest(path)
    package = Gem::Package.new(path)
    spec = package.spec

    {
      specification: normalized_specification(spec),
      name: spec.name,
      version: spec.version.to_s,
      platform: spec.platform.to_s,
      authors: spec.authors,
      email: spec.email,
      summary: spec.summary,
      description: spec.description,
      homepage: spec.homepage,
      licenses: spec.licenses,
      bindir: spec.bindir,
      required_ruby_version: spec.required_ruby_version.to_s,
      required_rubygems_version: spec.required_rubygems_version.to_s,
      require_paths: spec.require_paths.sort,
      executables: spec.executables.sort,
      extensions: spec.extensions.sort,
      plugins: spec.plugins.sort,
      post_install_message: spec.post_install_message,
      cert_chain: spec.cert_chain,
      requirements: spec.requirements.sort,
      dependencies: spec.dependencies.map { |dependency| [dependency.name, dependency.type, dependency.requirement.to_s] }.sort,
      metadata: spec.metadata.sort.to_h,
      files: spec.files.sort,
      archive: archive_entries(path)
    }
  end

  def verify_package!(path, version)
    package = manifest(path)
    errors = []
    errors << "gem name must be little_ghost" unless package.fetch(:name) == "little_ghost"
    errors << "gem version must be #{version}" unless package.fetch(:version) == version.to_s
    errors << "gem must support Ruby 3.3 and newer" unless package.fetch(:required_ruby_version) == ">= 3.3"

    files = package.fetch(:files)
    missing = REQUIRED_FILES - files
    errors << "gem is missing: #{missing.join(", ")}" unless missing.empty?
    excluded = files.grep(EXCLUDED_PATHS)
    errors << "gem includes repository-only files: #{excluded.join(", ")}" unless excluded.empty?

    archive = package.fetch(:archive)
    archive_paths = archive.map { |entry| entry.fetch(:path) }
    errors << "gem archive entries must exactly match gemspec files" unless archive_paths == files
    unsupported = archive.reject { |entry| entry.fetch(:type) == "0" }
    errors << "gem archive must contain only regular files" unless unsupported.empty?

    REQUIRED_METADATA.each do |key, value|
      errors << "gem metadata #{key} must be #{value.inspect}" unless package.fetch(:metadata)[key] == value
    end

    raise Error, errors.join("\n") unless errors.empty?

    package
  end

  def verify_published_package!(local_path, published_path)
    local = manifest(local_path)
    published = manifest(published_path)
    raise Error, "Published gem does not match the package built from this tag" unless published == local

    published
  end

  def extract(path, destination)
    Gem::Package.new(path).extract_files(destination)
  end

  def archive_entries(path)
    entries = []

    File.open(path, "rb") do |file|
      Gem::Package::TarReader.new(file).each do |gem_entry|
        next unless gem_entry.full_name == "data.tar.gz"

        Zlib::GzipReader.wrap(gem_entry) do |gzip|
          Gem::Package::TarReader.new(gzip).each do |entry|
            header = entry.header
            entries << {
              path: entry.full_name,
              type: header.typeflag,
              mode: header.mode,
              linkname: header.linkname,
              size: entry.size,
              sha256: entry.file? ? Digest::SHA256.hexdigest(entry.read) : nil
            }
          end
        end
      end
    end

    entries.sort_by { |entry| [entry.fetch(:path), entry.fetch(:type)] }
  end
  private_class_method :archive_entries

  def normalized_specification(specification)
    normalized = specification.dup
    normalized.date = Time.utc(1980, 1, 1)
    normalized.to_yaml
  end
  private_class_method :normalized_specification
end
