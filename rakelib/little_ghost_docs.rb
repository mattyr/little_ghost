# frozen_string_literal: true

require "digest"
require "bundler"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rubygems"
require "rubygems/package"
require "stringio"
require "tmpdir"

module LittleGhostDocs
  class Error < StandardError; end

  SITE_URL = "https://mattyr.github.io/little_ghost/"
  EDGE_ID = "edge"
  VERSION_DIRECTORY = "versions"
  CATALOG_FILE = "versions.json"
  ARCHIVE_MARKER = ".little-ghost-docs-archive"
  SELECTOR_ASSETS = %w[version-selector.css version-selector.js].freeze
  VERSION_LINK_PATTERN = %r{
    <a\s+class="(?<class>version-badge|navbar-version)"[^>]*>\s*(?<label>v[^<]+)\s*</a>
  }x

  module_function

  def stable_version!(value)
    version = Gem::Version.new(value.to_s)
    raise Error, "Documentation releases must use stable versions" if version.prerelease?

    version.to_s
  rescue ArgumentError
    raise Error, "Invalid documentation version #{value.inspect}"
  end

  class Snapshot
    def initialize(root, id:, base_path:, asset_source: File.expand_path("../site/assets", __dir__))
      @root = Pathname(root).expand_path
      @id = id.to_s
      @base_path = Pathname(base_path.to_s)
      @asset_source = Pathname(asset_source).expand_path
    end

    def decorate!
      raise Error, "Documentation site does not exist at #{root}" unless root.directory?

      decorated = false
      html_pages.each { |page| decorated = decorate_page(page) || decorated }
      copy_selector_assets if decorated
      ensure_selector_assets
      root.glob("**/created.rid").each(&:delete)
      self
    end

    private

    attr_reader :asset_source, :base_path, :id, :root

    def copy_selector_assets
      assets = root.join("assets")
      FileUtils.mkdir_p(assets)
      SELECTOR_ASSETS.each do |file_name|
        source = asset_source.join(file_name)
        raise Error, "Missing documentation selector asset #{source}" unless source.file?

        FileUtils.cp(source, assets.join(file_name))
      end
    end

    def ensure_selector_assets
      SELECTOR_ASSETS.each do |file_name|
        target = root.join("assets", file_name)
        raise Error, "Documentation snapshot is missing #{target}" unless target.file?
      end
    end

    def html_pages
      root.glob("**/*.html").sort
    end

    def decorate_page(page)
      html = page.read
      if html.include?("data-docs-version-picker")
        return false if html.include?(%(data-current-version="#{id}"))

        raise Error, "Documentation page #{page} is already decorated for another version"
      end

      match = html.match(VERSION_LINK_PATTERN)
      return false unless match

      relative_page = page.relative_path_from(root)
      deployed_page = base_path.join(relative_page)
      manifest_href = Pathname(CATALOG_FILE).relative_path_from(deployed_page.dirname)
      assets_root = base_path.join("assets")
      stylesheet_href = assets_root.join("version-selector.css").relative_path_from(deployed_page.dirname)
      script_href = assets_root.join("version-selector.js").relative_path_from(deployed_page.dirname)
      label = (id == EDGE_ID) ? "Edge" : "v#{id}"
      picker = <<~HTML.chomp
        <label class="#{match[:class]} docs-version-picker">
          <select aria-label="Documentation version" data-docs-version-picker
                  data-current-version="#{id}" data-current-page="#{relative_page}"
                  data-versions-url="#{manifest_href}">
            <option value="#{id}">#{label}</option>
          </select>
        </label>
      HTML

      html = html.sub(match[0], picker)
      html = add_stylesheet(html, stylesheet_href)
      html = html.sub("</body>", %(  <script type="module" src="#{script_href}"></script>\n</body>))
      html = rewrite_public_urls(html) unless base_path.to_s.empty? || base_path.to_s == "."
      page.write(html)
      true
    end

    def add_stylesheet(html, stylesheet_href)
      link = %(<link rel="stylesheet" href="#{stylesheet_href}">)
      return html.sub("</head>", "  #{link}\n</head>") if html.include?("</head>")
      return html.sub(%r{<body\b}, "  #{link}\n\n<body") if html.match?(%r{<body\b})

      raise Error, "Documentation page has no head or body boundary"
    end

    def rewrite_public_urls(html)
      html.gsub(SITE_URL, "#{SITE_URL}#{base_path}/")
    end
  end

  class Catalog
    def initialize(archive_root)
      @archive_root = Pathname(archive_root).expand_path
    end

    def write!
      archive_root.join(CATALOG_FILE).write(JSON.pretty_generate(to_h) << "\n")
      self
    end

    def verify!
      path = archive_root.join(CATALOG_FILE)
      raise Error, "Documentation archive is missing #{CATALOG_FILE}" unless path.file?
      if archive_root.glob("**/*", File::FNM_DOTMATCH).any?(&:symlink?)
        raise Error, "Documentation archive must not contain symbolic links"
      end

      actual = JSON.parse(path.read)
      expected = to_h
      raise Error, "Documentation version catalog is stale" unless actual == expected

      expected.fetch("versions").each do |entry|
        entry.fetch("pages").each do |page|
          target = entry.fetch("base_path").empty? ? archive_root.join(page) : archive_root.join(entry.fetch("base_path"), page)
          raise Error, "Documentation catalog points to missing #{target}" unless target.file?
        end
      end
      true
    end

    def to_h
      releases = release_entries
      {
        "default" => EDGE_ID,
        "latest_release" => releases.first&.fetch("id"),
        "versions" => [edge_entry, *releases]
      }
    end

    private

    attr_reader :archive_root

    def edge_entry
      {
        "id" => EDGE_ID,
        "label" => "Edge",
        "kind" => EDGE_ID,
        "base_path" => "",
        "pages" => pages_under(archive_root, exclude_versions: true)
      }
    end

    def release_entries
      versions_root = archive_root.join(VERSION_DIRECTORY)
      return [] unless versions_root.directory?

      versions_root.children.filter_map do |directory|
        next unless directory.directory?

        version = Gem::Version.new(directory.basename.to_s)
        next if version.prerelease?

        [version, {
          "id" => version.to_s,
          "label" => "v#{version}",
          "kind" => "release",
          "base_path" => "#{VERSION_DIRECTORY}/#{version}",
          "pages" => pages_under(directory)
        }]
      rescue ArgumentError
        nil
      end.sort_by(&:first).reverse.map(&:last)
    end

    def pages_under(directory, exclude_versions: false)
      directory.glob("**/*.html").filter_map do |page|
        relative = page.relative_path_from(directory).to_s
        next if exclude_versions && relative.start_with?("#{VERSION_DIRECTORY}/")

        relative
      end.sort
    end
  end

  class Archive
    def initialize(root, asset_source: File.expand_path("../site/assets", __dir__))
      @root = Pathname(root).expand_path
      @asset_source = asset_source
    end

    def publish_edge!(site)
      site = Pathname(site).expand_path
      prepare_root!(site:)
      Snapshot.new(site, id: EDGE_ID, base_path: "", asset_source: asset_source).decorate!
      clear_edge
      copy_children(site, root, excluding: [CATALOG_FILE])
      refresh_catalog
    end

    def publish_release!(site, version)
      version = LittleGhostDocs.stable_version!(version)
      site = Pathname(site).expand_path
      prepare_root!(site:)
      base_path = "#{VERSION_DIRECTORY}/#{version}"
      Snapshot.new(site, id: version, base_path:, asset_source: asset_source).decorate!
      destination = root.join(base_path)

      if destination.exist?
        raise Error, "Released documentation v#{version} is immutable" unless directory_digest(site) == directory_digest(destination)
      else
        FileUtils.mkdir_p(destination.parent)
        FileUtils.cp_r(site, destination)
      end

      refresh_catalog
    end

    def merge_releases!(candidate)
      candidate = Pathname(candidate).expand_path
      prepare_root!(site: candidate)
      candidate_versions = candidate.join(VERSION_DIRECTORY)
      candidate_releases = candidate_versions.directory? ? candidate_versions.children.select(&:directory?) : []
      candidate_names = candidate_releases.map { |path| path.basename.to_s }
      published_versions = root.join(VERSION_DIRECTORY)
      if published_versions.directory?
        unexpected = published_versions.children.select(&:directory?).map { |path| path.basename.to_s } - candidate_names
        raise Error, "Documentation archive contains unverified releases: #{unexpected.join(", ")}" if unexpected.any?
      end

      candidate_releases.sort.each do |release|
        publish_release!(release, release.basename.to_s)
      end
      verify!
    end

    def verify!
      Catalog.new(root).verify!
    end

    private

    attr_reader :asset_source, :root

    def prepare_root!(site:)
      raise Error, "Documentation archive root cannot be a symbolic link" if root.symlink?
      raise Error, "Documentation archive source cannot overlap its destination" if overlapping_paths?(root, site)

      dangerous_roots = [Pathname("/").expand_path, Pathname(Dir.home).expand_path, repository_root]
      if dangerous_roots.any? { |path| root == path || path.to_s.start_with?("#{root}#{File::SEPARATOR}") }
        raise Error, "Refusing unsafe documentation archive root #{root}"
      end

      FileUtils.mkdir_p(root)
      marker = root.join(ARCHIVE_MARKER)
      unless marker.file? || root.children.empty? || docs_archive_checkout?
        raise Error, "Documentation archive root is missing #{ARCHIVE_MARKER}"
      end
      marker.write("Generated documentation archive. Do not edit by hand.\n")
    end

    def repository_root
      Pathname(asset_source).expand_path.parent.parent
    end

    def overlapping_paths?(left, right)
      left == right || left.to_s.start_with?("#{right}#{File::SEPARATOR}") || right.to_s.start_with?("#{left}#{File::SEPARATOR}")
    end

    def docs_archive_checkout?
      return false unless root.join(".git").exist?

      branch, status = Open3.capture2("git", "-C", root.to_s, "branch", "--show-current")
      status.success? && branch.strip == "docs-archive"
    end

    def clear_edge
      root.children.each do |child|
        next if [".git", ARCHIVE_MARKER, VERSION_DIRECTORY].include?(child.basename.to_s)

        FileUtils.rm_rf(child)
      end
    end

    def copy_children(source, destination, excluding:)
      source.children.each do |child|
        next if excluding.include?(child.basename.to_s)

        FileUtils.cp_r(child, destination)
      end
    end

    def refresh_catalog
      Catalog.new(root).write!.verify!
      self
    end

    def directory_digest(directory)
      digest = Digest::SHA256.new
      Pathname(directory).glob("**/*", File::FNM_DOTMATCH).sort.each do |path|
        next if [".", "..", CATALOG_FILE].include?(path.basename.to_s) || path.directory?

        digest << path.relative_path_from(directory).to_s << "\0" << path.binread << "\0"
      end
      digest.hexdigest
    end
  end

  class ReleaseSync
    def initialize(repository:, archive:, command_runner: Kernel.method(:system), capture_runner: Open3.method(:capture3))
      @repository = Pathname(repository).expand_path
      @archive = Archive.new(archive, asset_source: @repository.join("site/release-compat/v1"))
      @command_runner = command_runner
      @capture_runner = capture_runner
    end

    def add!(version:, commit:)
      version = LittleGhostDocs.stable_version!(version)
      Dir.mktmpdir("little-ghost-docs-#{version}") do |directory|
        source = Pathname(directory).join("source")
        FileUtils.mkdir_p(source)
        extract_commit(commit, source)
        return false unless source.join("Rakefile").read.match?(/^namespace :site do$/)

        run_command!("bundle", "install", "--jobs", "4", chdir: source.to_s)
        if source.join("rakelib/little_ghost_docs.rb").file?
          run_command!(
            "bundle", "exec", "rake", "site:build",
            chdir: source.to_s,
            env: {"DOCS_VERSION_ID" => version, "DOCS_BASE_PATH" => "#{VERSION_DIRECTORY}/#{version}"}
          )
        else
          run_command!("bundle", "exec", "rake", "site:check", chdir: source.to_s)
        end
        archive.publish_release!(source.join("_site"), version)
      end
      archive.verify!
    end

    private

    attr_reader :archive, :capture_runner, :command_runner, :repository

    def extract_commit(commit, destination)
      archive_data, error, status = capture_runner.call("git", "archive", "--format=tar", commit, chdir: repository.to_s)
      raise Error, "Could not export documentation commit #{commit}: #{error}" unless status.success?

      Gem::Package::TarReader.new(StringIO.new(archive_data)) do |tar|
        tar.each do |entry|
          target = destination.join(entry.full_name).cleanpath
          unless target == destination || target.to_s.start_with?("#{destination}#{File::SEPARATOR}")
            raise Error, "Documentation archive contains an unsafe path"
          end

          if entry.directory?
            FileUtils.mkdir_p(target)
          elsif entry.file?
            FileUtils.mkdir_p(target.dirname)
            File.binwrite(target, entry.read)
            FileUtils.chmod(entry.header.mode, target)
          end
        end
      end
    end

    def run_command!(*command, chdir:, env: {})
      succeeded = Bundler.with_unbundled_env do
        command_runner.call(env, *command, chdir:)
      end
      return if succeeded

      raise Error, "Documentation command failed: #{command.join(" ")}"
    end
  end
end
