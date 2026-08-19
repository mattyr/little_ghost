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
require "uri"

module LittleGhostDocs
  class Error < StandardError; end

  SITE_URL = "https://littleghostai.org/"
  LEGACY_SITE_URL = "https://mattyr.github.io/little_ghost/"
  UNVERSIONED_SITE_URL_PATTERN = %r{#{Regexp.escape(SITE_URL)}(?!versions(?:/|\.json))}
  EDGE_ID = "edge"
  VERSION_DIRECTORY = "versions"
  CATALOG_FILE = "versions.json"
  SITE_MARKER = ".little-ghost-versioned-site"
  SELECTOR_ASSETS = %w[version-selector.css version-selector.js].freeze
  VERSION_LINK_PATTERN = %r{
    <a\s+class="(?<class>version-badge|navbar-version)"[^>]*>\s*(?<label>v[^<]+)\s*</a>
  }x
  GUIDES = [
    {source: "docs/guides/getting_started.md", output: "getting_started.html", title: "Getting Started", section: "Learn"},
    {source: "docs/guides/core_concepts.md", output: "core_concepts.html", title: "Core Concepts", section: "Learn"},
    {source: "docs/guides/models_and_providers.md", output: "models_and_providers.html", title: "Models and Providers", section: "Learn"},
    {source: "docs/guides/structured_outputs_and_content.md", output: "structured_outputs_and_content.html", title: "Structured Outputs and Content", section: "Build with agents"},
    {source: "docs/guides/assemblies.md", output: "assemblies.html", title: "Compose Agents", section: "Build with agents"},
    {source: "docs/guides/prompt_views.md", output: "prompt_views.html", title: "Prompts as Views", section: "Build with agents"},
    {source: "docs/guides/tools.md", output: "tools.html", title: "Tools", section: "Capabilities and isolation"},
    {source: "docs/guides/skills.md", output: "skills.html", title: "Skills", section: "Capabilities and isolation"},
    {source: "docs/guides/sandboxing.md", output: "sandboxing.html", title: "Workspaces and Sandboxes", section: "Capabilities and isolation"},
    {source: "docs/guides/code_mode.md", output: "code_mode.html", title: "Code Mode", section: "Capabilities and isolation"},
    {source: "docs/guides/integrations.md", output: "integrations.html", title: "Integrations", section: "Operate"},
    {source: "docs/guides/production.md", output: "production.html", title: "Running in Production", section: "Operate"}
  ].freeze
  GUIDE_PATHS = GUIDES.to_h { |guide| [guide.fetch(:source), guide.fetch(:output)] }.freeze
  GUIDE_TITLES = GUIDES.to_h { |guide| [guide.fetch(:source), guide.fetch(:title)] }.freeze
  GUIDE_SECTIONS = GUIDES.group_by { |guide| guide.fetch(:section) }.transform_values do |guides|
    guides.map { |guide| guide.fetch(:source) }
  end.freeze

  module_function

  def stable_version!(value)
    version = Gem::Version.new(value.to_s)
    raise Error, "Documentation releases must use stable versions" if version.prerelease?

    version.to_s
  rescue ArgumentError
    raise Error, "Invalid documentation version #{value.inspect}"
  end

  def markdown_anchors(markdown)
    anchors = markdown.scan(/<a\s+[^>]*id=["']([^"']+)["'][^>]*>/i).flatten.to_h { |anchor| [anchor, true] }
    occurrences = Hash.new(0)
    markdown.each_line do |line|
      match = line.match(/\A\#{1,6}\s+(.+?)\s*#*\s*\z/)
      next unless match

      label = match[1].gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1").gsub(/<[^>]+>/, "").gsub(/[`*_~]/, "")
      slug = label.downcase.gsub(/[^\p{Alnum}_\s-]/u, "").strip.gsub(/\s+/, "-")
      next if slug.empty?

      occurrence = occurrences[slug]
      occurrences[slug] += 1
      anchor = occurrence.zero? ? slug : "#{slug}-#{occurrence}"
      anchors[anchor] = true
    end
    anchors
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

      picker_added = false
      html_pages.each { |page| picker_added = decorate_page(page) || picker_added }
      copy_selector_assets if picker_added
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
      relative_page = page.relative_path_from(root)
      changed = false
      picker_added = false

      if html.include?("data-docs-version-picker")
        unless html.include?(%(data-current-version="#{id}"))
          raise Error, "Documentation page #{page} is already decorated for another version"
        end
      elsif (match = html.match(VERSION_LINK_PATTERN))
        html = add_version_picker(html, match, relative_page)
        changed = true
        picker_added = true
      end

      rewritten_html = rewrite_public_urls(html)
      changed = true if rewritten_html != html
      html = rewritten_html

      unless relative_page.basename.to_s == "404.html"
        canonical_html = add_canonical(html, relative_page)
        changed = true if canonical_html != html
        html = canonical_html
      end

      markdown_page = root.join(relative_page.sub_ext(".md"))
      if markdown_page.file? && !html.include?('rel="alternate" type="text/markdown"')
        html = add_markdown_alternate(html, relative_page)
        changed = true
      end

      page.write(html) if changed
      picker_added
    end

    def add_version_picker(html, match, relative_page)
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
      html.sub("</body>", %(  <script type="module" src="#{script_href}"></script>\n</body>))
    end

    def add_markdown_alternate(html, relative_page)
      markdown_path = base_path.join(relative_page.sub_ext(".md"))
      markdown_url = URI.join(SITE_URL, "#{markdown_path}/".delete_suffix("/")).to_s
      head_link = %(<link rel="alternate" type="text/markdown" href="#{markdown_url}">)
      hidden_link = <<~HTML.chomp
        <a class="docs-markdown-link visually-hidden" href="#{markdown_url}" aria-hidden="true" tabindex="-1">Markdown version of this page</a>
      HTML
      html = if html.include?("</head>")
        html.sub("</head>", "  #{head_link}\n</head>")
      elsif html.match?(%r{<body\b})
        html.sub(%r{<body\b}, "#{head_link}\n\n<body")
      else
        raise Error, "Documentation page has no head or body boundary"
      end
      html.sub("</body>", "  #{hidden_link}\n</body>")
    end

    def add_canonical(html, relative_page)
      canonical = %(<link rel="canonical" href="#{canonical_url(relative_page)}">)
      return html.sub(%r{<link\s+rel=["']canonical["'][^>]*>}, canonical) if html.match?(%r{<link\s+rel=["']canonical["'][^>]*>})
      return html.sub("</head>", "  #{canonical}\n</head>") if html.include?("</head>")
      return html.sub(%r{<body\b}, "#{canonical}\n\n<body") if html.match?(%r{<body\b})

      raise Error, "Documentation page has no head or body boundary"
    end

    def canonical_url(relative_page)
      if relative_page.basename.to_s == "index.html"
        directory = relative_page.dirname.to_s
        path = base_path.join((directory == ".") ? "" : directory).cleanpath.to_s
        path = "" if path == "."
        path = "#{path}/" unless path.empty?
        URI.join(SITE_URL, path).to_s
      else
        URI.join(SITE_URL, base_path.join(relative_page).to_s).to_s
      end
    end

    def add_stylesheet(html, stylesheet_href)
      link = %(<link rel="stylesheet" href="#{stylesheet_href}">)
      return html.sub("</head>", "  #{link}\n</head>") if html.include?("</head>")
      return html.sub(%r{<body\b}, "  #{link}\n\n<body") if html.match?(%r{<body\b})

      raise Error, "Documentation page has no head or body boundary"
    end

    def rewrite_public_urls(html)
      rewritten = html.gsub(LEGACY_SITE_URL, SITE_URL)
      return rewritten if base_path.to_s.empty? || base_path.to_s == "."

      deployed_url = URI.join(SITE_URL, "#{base_path}/").to_s
      rewritten.gsub(UNVERSIONED_SITE_URL_PATTERN, deployed_url)
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
      raise Error, "Versioned documentation is missing #{CATALOG_FILE}" unless path.file?
      if archive_root.glob("**/*", File::FNM_DOTMATCH).any?(&:symlink?)
        raise Error, "Versioned documentation must not contain symbolic links"
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

  class VersionedSite
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

    def verify!
      Catalog.new(root).verify!
    end

    private

    attr_reader :asset_source, :root

    def prepare_root!(site:)
      raise Error, "Versioned documentation root cannot be a symbolic link" if root.symlink?
      raise Error, "Versioned documentation source cannot overlap its destination" if overlapping_paths?(root, site)

      dangerous_roots = [Pathname("/").expand_path, Pathname(Dir.home).expand_path, repository_root]
      if dangerous_roots.any? { |path| root == path || path.to_s.start_with?("#{root}#{File::SEPARATOR}") }
        raise Error, "Refusing unsafe versioned documentation root #{root}"
      end

      FileUtils.mkdir_p(root)
      marker = root.join(SITE_MARKER)
      unless marker.file? || root.children.empty?
        raise Error, "Versioned documentation root is missing #{SITE_MARKER}"
      end
      marker.write("Generated versioned documentation. Do not edit by hand.\n")
    end

    def repository_root
      Pathname(asset_source).expand_path.parent.parent
    end

    def overlapping_paths?(left, right)
      left == right || left.to_s.start_with?("#{right}#{File::SEPARATOR}") || right.to_s.start_with?("#{left}#{File::SEPARATOR}")
    end

    def clear_edge
      root.children.each do |child|
        next if [SITE_MARKER, VERSION_DIRECTORY].include?(child.basename.to_s)

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

  Release = Data.define(:version, :commit)

  class PublishedReleases
    include Enumerable

    def initialize(repository:, capture_runner: Open3.method(:capture3))
      @repository = Pathname(repository).expand_path
      @capture_runner = capture_runner
    end

    def each
      return enum_for(:each) unless block_given?

      release_tags.each do |tag|
        version = LittleGhostDocs.stable_version!(tag.delete_prefix("v"))
        raise Error, "Release #{tag} has an unexpected tag" unless tag == "v#{version}"

        verify_publication!(tag, version)
        tag_object = capture!("git", "rev-parse", "--verify", "refs/tags/#{tag}^{tag}").strip
        tag_data = JSON.parse(capture!("gh", "api", "repos/#{github_repository}/git/tags/#{tag_object}"))
        target = tag_data.fetch("object")
        raise Error, "Documentation release #{tag} does not have an annotated commit tag" unless target.fetch("type") == "commit"

        commit = target.fetch("sha")
        capture!("git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main")
        declared_version = source_version(commit)
        unless declared_version == version
          raise Error, "Documentation release #{tag} does not match source version #{declared_version}"
        end

        yield Release.new(version:, commit:)
      end
    end

    private

    attr_reader :capture_runner, :repository

    def release_tags
      capture!("git", "fetch", "origin", "main:refs/remotes/origin/main", "--tags")
      capture!(
        "gh", "api", "--paginate", "repos/#{github_repository}/releases",
        "--jq", ".[] | select(.draft == false and .prerelease == false) | .tag_name"
      ).lines(chomp: true).reject(&:empty?)
    end

    def github_repository
      @github_repository ||= ENV["GITHUB_REPOSITORY"] || begin
        remote = capture!("git", "remote", "get-url", "origin").strip
        match = remote.match(%r{(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?\z})
        raise Error, "Could not identify the GitHub repository from #{remote.inspect}" unless match

        match[1]
      end
    end

    def source_version(commit)
      source = capture!("git", "show", "#{commit}:lib/little_ghost/version.rb")
      source[/^\s*VERSION = "([^"]+)"/, 1]
    end

    def verify_publication!(tag, version)
      release = JSON.parse(capture!("gh", "api", "repos/#{github_repository}/releases/tags/#{tag}"))
      expected_assets = ["little_ghost-#{version}.gem", "little_ghost-#{version}.gem.sha256"]
      actual_assets = release.fetch("assets").map { |asset| asset.fetch("name") }.sort
      automated = release.dig("author", "login") == "github-actions[bot]" &&
        release.fetch("assets").all? { |asset| asset.dig("uploader", "login") == "github-actions[bot]" }
      return if automated && actual_assets == expected_assets.sort

      raise Error, "Documentation release #{tag} was not published by the trusted release workflow"
    end

    def capture!(*command)
      output, error, status = capture_runner.call(*command, chdir: repository.to_s)
      return output if status.success?

      detail = error.strip
      detail = output.strip if detail.empty?
      raise Error, "Documentation command failed: #{command.join(" ")}#{": #{detail}" unless detail.empty?}"
    end
  end

  class SiteBuilder
    def initialize(repository:, edge_site:, releases: nil, release_builder: nil)
      @repository = Pathname(repository).expand_path
      @edge_site = Pathname(edge_site).expand_path
      @releases = releases || PublishedReleases.new(repository: @repository)
      @release_builder = release_builder
    end

    def build!(destination)
      destination = Pathname(destination).expand_path
      raise Error, "Versioned documentation destination cannot be a symbolic link" if destination.symlink?

      FileUtils.mkdir_p(destination)
      raise Error, "Versioned documentation destination must be empty" unless destination.children.empty?

      site = VersionedSite.new(destination)
      site.publish_edge!(edge_site)
      release_builder ? build_with_injected_builder : build_releases_in_parallel(site)
      site.verify!
      destination
    end

    private

    attr_reader :edge_site, :release_builder, :releases, :repository

    def build_with_injected_builder
      releases.each do |release|
        release_builder.add!(version: release.version, commit: release.commit)
      end
    end

    def build_releases_in_parallel(site)
      release_list = releases.to_a
      return if release_list.empty?

      worker_count = Integer(ENV.fetch("DOCS_BUILD_JOBS", [release_list.length, 4].min.to_s), 10)
      raise Error, "DOCS_BUILD_JOBS must be at least 1" if worker_count < 1

      command_environment = ReleaseBuilder.command_environment
      Dir.mktmpdir("little-ghost-release-sites") do |directory|
        queue = Queue.new
        release_list.each { |release| queue << release }
        results = {}
        results_lock = Mutex.new
        errors = Queue.new
        workers = [worker_count, release_list.length].min.times.map do
          Thread.new do
            loop do
              release = queue.pop(true)
              release_site = Pathname(directory).join(release.version)
              ReleaseBuilder.new(repository:, site: release_site, command_environment:).add!(
                version: release.version,
                commit: release.commit
              )
              results_lock.synchronize do
                results[release.version] = release_site.join(VERSION_DIRECTORY, release.version)
              end
            rescue ThreadError
              break
            rescue => error
              errors << error
              break
            end
          end
        end
        workers.each(&:join)
        raise errors.pop unless errors.empty?

        release_list.each do |release|
          release_site = results.fetch(release.version)
          site.publish_release!(release_site, release.version)
        end
      end
    end
  end

  class ReleaseBuilder
    PRIVATE_ENVIRONMENT = %w[
      ACTIONS_ID_TOKEN_REQUEST_TOKEN
      ACTIONS_ID_TOKEN_REQUEST_URL
      GH_TOKEN
      GITHUB_TOKEN
    ].to_h { |name| [name, nil] }.freeze

    def self.command_environment
      original = ENV.to_h
      unbundled = Bundler.with_unbundled_env { ENV.to_h }
      (original.keys | unbundled.keys).to_h do |name|
        [name, unbundled.key?(name) ? unbundled[name] : nil]
      end.select { |name, value| original[name] != value }
    end

    def initialize(
      repository:,
      site:,
      command_runner: Kernel.method(:system),
      capture_runner: Open3.method(:capture3),
      command_environment: self.class.command_environment
    )
      @repository = Pathname(repository).expand_path
      @site = VersionedSite.new(site, asset_source: @repository.join("site/release-compat/v1"))
      @command_runner = command_runner
      @capture_runner = capture_runner
      @command_environment = command_environment
    end

    def add!(version:, commit:)
      version = LittleGhostDocs.stable_version!(version)
      Dir.mktmpdir("little-ghost-docs-#{version}") do |directory|
        temporary_root = Pathname(directory)
        source = temporary_root.join("source")
        bundle_environment = isolated_bundle_environment(temporary_root)
        FileUtils.mkdir_p(source)
        extract_commit(commit, source)
        unless source.join("Rakefile").read.match?(/^namespace :site do$/)
          raise Error, "Documentation release v#{version} does not support versioned site builds"
        end

        run_command!("bundle", "install", chdir: source.to_s, env: bundle_environment)
        if source.join("rakelib/little_ghost_docs.rb").file?
          run_command!(
            "bundle", "exec", "rake", "site:build",
            chdir: source.to_s,
            env: bundle_environment.merge(
              "DOCS_VERSION_ID" => version,
              "DOCS_BASE_PATH" => "#{VERSION_DIRECTORY}/#{version}"
            )
          )
        else
          run_command!("bundle", "exec", "rake", "site:check", chdir: source.to_s, env: bundle_environment)
        end
        MarkdownSite.build_from_source(
          source_root: source,
          site_root: source.join("_site"),
          id: version,
          base_path: "#{VERSION_DIRECTORY}/#{version}"
        )
        site.publish_release!(source.join("_site"), version)
      end
      site.verify!
    rescue Error => error
      raise Error, "Documentation release v#{version} failed: #{error.message}", cause: error
    end

    private

    attr_reader :capture_runner, :command_environment, :command_runner, :repository, :site

    def isolated_bundle_environment(temporary_root)
      temporary_root = Pathname(temporary_root)
      {
        "BUNDLE_APP_CONFIG" => temporary_root.join("bundle-config").to_s,
        "BUNDLE_DISABLE_SHARED_GEMS" => "true",
        "BUNDLE_FROZEN" => "true",
        "BUNDLE_JOBS" => "1",
        "BUNDLE_PATH" => temporary_root.join("bundle").to_s
      }
    end

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
      subprocess_environment = command_environment.merge(env).merge(PRIVATE_ENVIRONMENT)
      succeeded = command_runner.call(subprocess_environment, *command, chdir:)
      return if succeeded

      raise Error, "Documentation command failed: #{command.join(" ")}"
    end
  end
end

require_relative "little_ghost_markdown"
