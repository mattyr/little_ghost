# frozen_string_literal: true

require "test_helper"
require_relative "../rakelib/little_ghost_docs"
require "cgi/escape"

class LittleGhostDocsTest < Minitest::Test
  def test_homepage_graph_demo_uses_generic_edges
    homepage = File.read(File.expand_path("../site/index.html", __dir__))
    graph_demo = homepage.match(/<section class="demo-section" id="agent-graph".*?<\/section>/m).to_s
    visible_lines = graph_demo.scan(/<span class="typed-text"[^>]*>(.*?)<\/span><\/div>/m).flatten.map do |line|
      CGI.unescapeHTML(line.gsub(/<[^>]+>/, ""))
    end

    expected_edges = [
      "  edge :triage, :order",
      "  edge :triage, :policy",
      "  edge :order, :respond",
      "  edge :policy, :respond"
    ]
    expected_edges.each do |edge|
      assert_includes graph_demo, %(data-plain="#{edge}")
      assert_includes visible_lines, edge
    end
    refute_match(/data-plain="  (?:fork|join) /, graph_demo)
    refute visible_lines.any? { |line| line.match?(/^  (?:fork|join) /) }
  end

  def test_snapshot_adds_edge_selector_assets_and_catalog_location
    Dir.mktmpdir("little-ghost-docs") do |directory|
      site = build_site(directory, "site", version: "0.3.0")

      LittleGhostDocs::Snapshot.new(site, id: "edge", base_path: "").decorate!

      homepage = File.read(File.join(site, "index.html"))
      agent = File.read(File.join(site, "docs", "LittleGhost", "Agent.html"))
      assert_includes homepage, 'data-current-version="edge"'
      assert_includes homepage, 'data-versions-url="versions.json"'
      refute_includes homepage, "data-docs-version-notice"
      assert_includes agent, 'data-current-page="docs/LittleGhost/Agent.html"'
      assert_includes agent, 'data-versions-url="../../versions.json"'
      assert_path_exists File.join(site, "assets", "version-selector.css")
      assert_path_exists File.join(site, "assets", "version-selector.js")
    end
  end

  def test_release_snapshot_uses_versioned_urls_and_rewrites_canonical_metadata
    Dir.mktmpdir("little-ghost-docs") do |directory|
      site = build_site(directory, "site", version: "0.2.0")

      LittleGhostDocs::Snapshot.new(site, id: "0.2.0", base_path: "versions/0.2.0").decorate!

      homepage = File.read(File.join(site, "index.html"))
      agent = File.read(File.join(site, "docs", "LittleGhost", "Agent.html"))
      assert_includes homepage, 'data-current-version="0.2.0"'
      assert_includes homepage, 'data-versions-url="../../versions.json"'
      assert_includes homepage, "https://mattyr.github.io/little_ghost/versions/0.2.0/"
      assert_includes agent, 'data-versions-url="../../../../versions.json"'
    end
  end

  def test_snapshot_adds_stylesheet_to_legacy_rdoc_without_a_closing_head
    Dir.mktmpdir("little-ghost-docs") do |directory|
      site = build_site(directory, "site", version: "0.2.0")
      agent_path = File.join(site, "docs", "LittleGhost", "Agent.html")
      File.write(agent_path, File.read(agent_path).sub("</head>", ""))

      LittleGhostDocs::Snapshot.new(site, id: "0.2.0", base_path: "versions/0.2.0").decorate!

      agent = File.read(agent_path)
      assert_includes agent, '<link rel="stylesheet" href="../../assets/version-selector.css">'
      assert_operator agent.index("version-selector.css"), :<, agent.index("<body")
    end
  end

  def test_versioned_site_combines_edge_and_release_snapshots
    Dir.mktmpdir("little-ghost-docs") do |directory|
      archive = File.join(directory, "archive")
      edge = build_site(directory, "edge", version: "0.4.0", pages: %w[Agent Assembly])
      release = build_site(directory, "release", version: "0.3.0", pages: %w[Agent])
      docs = LittleGhostDocs::VersionedSite.new(archive)

      docs.publish_edge!(edge)
      docs.publish_release!(release, "0.3.0")

      catalog = JSON.parse(File.read(File.join(archive, "versions.json")))
      assert_equal "edge", catalog.fetch("default")
      assert_equal "0.3.0", catalog.fetch("latest_release")
      assert_equal %w[edge 0.3.0], catalog.fetch("versions").map { |entry| entry.fetch("id") }
      edge_entry, release_entry = catalog.fetch("versions")
      assert_includes edge_entry.fetch("pages"), "docs/LittleGhost/Assembly.html"
      refute_includes release_entry.fetch("pages"), "docs/LittleGhost/Assembly.html"

      docs.publish_release!(release, "0.3.0")
      File.write(File.join(release, "index.html"), "changed")
      error = assert_raises(LittleGhostDocs::Error) do
        docs.publish_release!(release, "0.3.0")
      end
      assert_equal "Released documentation v0.3.0 is immutable", error.message

      replacement = build_site(directory, "replacement", version: "0.5.0", pages: %w[Agent Graph])
      docs.publish_edge!(replacement)
      assert_path_exists File.join(archive, "docs", "LittleGhost", "Graph.html")
      assert_path_exists File.join(archive, "versions", "0.3.0", "index.html")
      docs.verify!
    end
  end

  def test_catalog_sorts_stable_versions_and_ignores_unrelated_directories
    Dir.mktmpdir("little-ghost-docs") do |directory|
      archive = File.join(directory, "archive")
      docs = LittleGhostDocs::VersionedSite.new(archive)
      docs.publish_edge!(build_site(directory, "edge", version: "0.4.0"))
      docs.publish_release!(build_site(directory, "older", version: "0.1.0"), "0.1.0")
      docs.publish_release!(build_site(directory, "newer", version: "0.3.0"), "0.3.0")
      FileUtils.mkdir_p(File.join(archive, "versions", "notes"))
      LittleGhostDocs::Catalog.new(archive).write!

      catalog = JSON.parse(File.read(File.join(archive, "versions.json")))
      assert_equal %w[edge 0.3.0 0.1.0], catalog.fetch("versions").map { |entry| entry.fetch("id") }
    end
  end

  def test_versioned_site_rejects_prerelease_versions
    Dir.mktmpdir("little-ghost-docs") do |directory|
      archive = LittleGhostDocs::VersionedSite.new(File.join(directory, "archive"))
      site = build_site(directory, "site", version: "0.4.0.pre")

      error = assert_raises(LittleGhostDocs::Error) do
        archive.publish_release!(site, "0.4.0.pre")
      end
      assert_equal "Documentation releases must use stable versions", error.message
    end
  end

  def test_versioned_site_preserves_assets_from_an_already_decorated_release
    Dir.mktmpdir("little-ghost-docs") do |directory|
      release = build_site(directory, "release", version: "1.0.0")
      original_assets = build_selector_assets(directory, "original", "release assets")
      current_assets = build_selector_assets(directory, "current", "edge assets")
      LittleGhostDocs::Snapshot.new(
        release,
        id: "1.0.0",
        base_path: "versions/1.0.0",
        asset_source: original_assets
      ).decorate!

      archive = File.join(directory, "archive")
      LittleGhostDocs::VersionedSite.new(archive, asset_source: current_assets).publish_release!(release, "1.0.0")

      assert_equal "release assets", File.read(File.join(archive, "versions", "1.0.0", "assets", "version-selector.js"))
    end
  end

  def test_edge_publication_rejects_an_unmarked_or_overlapping_destination
    Dir.mktmpdir("little-ghost-docs") do |directory|
      site = build_site(directory, "site", version: "0.4.0")
      unmarked = File.join(directory, "unmarked")
      FileUtils.mkdir_p(unmarked)
      sentinel = File.join(unmarked, "keep-me.txt")
      File.write(sentinel, "safe")

      error = assert_raises(LittleGhostDocs::Error) do
        LittleGhostDocs::VersionedSite.new(unmarked).publish_edge!(site)
      end
      assert_includes error.message, LittleGhostDocs::SITE_MARKER
      assert_equal "safe", File.read(sentinel)

      error = assert_raises(LittleGhostDocs::Error) do
        LittleGhostDocs::VersionedSite.new(site).publish_edge!(site)
      end
      assert_equal "Versioned documentation source cannot overlap its destination", error.message
    end
  end

  def test_site_builder_rebuilds_edge_and_each_published_release
    Dir.mktmpdir("little-ghost-docs") do |directory|
      edge = build_site(directory, "current-edge", version: "0.5.0", pages: %w[Agent Graph])
      destination = File.join(directory, "preview")
      releases = [LittleGhostDocs::Release.new(version: "0.3.0", commit: "release-commit")]
      release_site = build_site(directory, "release", version: "0.3.0")
      built = []
      release_builder = Object.new
      release_builder.define_singleton_method(:add!) do |version:, commit:|
        built << [version, commit]
        LittleGhostDocs::VersionedSite.new(destination).publish_release!(
          release_site,
          version
        )
      end

      result = LittleGhostDocs::SiteBuilder.new(
        repository: directory,
        edge_site: edge,
        releases:,
        release_builder:
      ).build!(destination)

      assert_equal Pathname(destination).expand_path, result
      assert_path_exists File.join(destination, "docs", "LittleGhost", "Graph.html")
      assert_path_exists File.join(destination, "versions", "0.3.0", "index.html")
      catalog = JSON.parse(File.read(File.join(destination, "versions.json")))
      assert_equal %w[edge 0.3.0], catalog.fetch("versions").map { |entry| entry.fetch("id") }
      assert_equal [["0.3.0", "release-commit"]], built
    end
  end

  def test_published_releases_are_stable_annotated_tags_from_main_with_matching_source
    original_repository = ENV.delete("GITHUB_REPOSITORY")
    commands = []
    responses = [
      ["", ""],
      ["git@github.com:mattyr/little_ghost.git\n", ""],
      ["v0.3.0\n", ""],
      [JSON.generate(
        "author" => {"login" => "github-actions[bot]"},
        "assets" => [
          {"name" => "little_ghost-0.3.0.gem", "uploader" => {"login" => "github-actions[bot]"}},
          {"name" => "little_ghost-0.3.0.gem.sha256", "uploader" => {"login" => "github-actions[bot]"}}
        ]
      ), ""],
      ["tag-object\n", ""],
      [JSON.generate("object" => {"type" => "commit", "sha" => "release-commit"}), ""],
      ["", ""],
      ["module LittleGhost\n  VERSION = \"0.3.0\"\nend\n", ""]
    ]
    capture_runner = lambda do |*command, chdir:|
      commands << [command, chdir]
      output, error = responses.shift
      [output, error, successful_status]
    end

    releases = LittleGhostDocs::PublishedReleases.new(
      repository: "/project",
      capture_runner:
    ).to_a

    assert_equal [LittleGhostDocs::Release.new(version: "0.3.0", commit: "release-commit")], releases
    assert_equal [
      ["git", "fetch", "origin", "main:refs/remotes/origin/main", "--tags"],
      ["git", "remote", "get-url", "origin"],
      ["gh", "api", "--paginate", "repos/mattyr/little_ghost/releases", "--jq",
        ".[] | select(.draft == false and .prerelease == false) | .tag_name"],
      ["gh", "api", "repos/mattyr/little_ghost/releases/tags/v0.3.0"],
      ["git", "rev-parse", "--verify", "refs/tags/v0.3.0^{tag}"],
      ["gh", "api", "repos/mattyr/little_ghost/git/tags/tag-object"],
      ["git", "merge-base", "--is-ancestor", "release-commit", "refs/remotes/origin/main"],
      ["git", "show", "release-commit:lib/little_ghost/version.rb"]
    ], commands.map(&:first)
  ensure
    ENV["GITHUB_REPOSITORY"] = original_repository if original_repository
  end

  def test_release_builds_do_not_inherit_workflow_tokens
    captured_environment = nil
    command_runner = lambda do |environment, *_command, chdir:|
      captured_environment = environment
      true
    end
    builder = LittleGhostDocs::ReleaseBuilder.new(
      repository: "/project",
      site: "/versioned-site",
      command_runner:
    )

    builder.send(:run_command!, "bundle", "install", chdir: "/release")

    assert_nil captured_environment.fetch("GH_TOKEN")
    assert_nil captured_environment.fetch("GITHUB_TOKEN")
    assert_nil captured_environment.fetch("ACTIONS_ID_TOKEN_REQUEST_URL")
    assert_nil captured_environment.fetch("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
  end

  def test_workflows_rebuild_the_complete_site_without_a_persistent_branch
    docs_workflow = File.read(File.expand_path("../.github/workflows/docs.yml", __dir__))
    release_workflow = File.read(File.expand_path("../.github/workflows/release.yml", __dir__))

    assert_includes docs_workflow, "workflow_run:"
    assert_includes docs_workflow, "release:"
    assert_includes docs_workflow, "bundle exec rake site:build_all"
    assert_includes docs_workflow, "versioned-site.tgz"
    assert_includes docs_workflow, "event=push"
    assert_includes docs_workflow, "Require the current published release set"
    assert_includes docs_workflow, "little-ghost-documentation-publish"
    refute_includes docs_workflow, "docs-archive"
    assert_includes release_workflow, 'gh workflow run docs.yml --ref main -f expected_release="$GITHUB_REF_NAME"'
    refute_includes release_workflow, "bundle exec rake site:build_all"
    refute_includes release_workflow, "docs-archive"
  end

  private

  def successful_status
    status = Object.new
    status.define_singleton_method(:success?) { true }
    status
  end

  def build_site(directory, name, version:, pages: %w[Agent])
    root = File.join(directory, name)
    FileUtils.mkdir_p(File.join(root, "docs", "LittleGhost"))
    FileUtils.mkdir_p(File.join(root, "assets"))
    File.write(File.join(root, "index.html"), homepage(version))
    File.write(File.join(root, "docs", "index.html"), docs_page("Docs", version))
    pages.each do |page|
      File.write(File.join(root, "docs", "LittleGhost", "#{page}.html"), docs_page(page, version))
    end
    root
  end

  def build_selector_assets(directory, name, contents)
    root = File.join(directory, name)
    FileUtils.mkdir_p(root)
    LittleGhostDocs::SELECTOR_ASSETS.each do |file_name|
      File.write(File.join(root, file_name), contents)
    end
    root
  end

  def homepage(version)
    <<~HTML
      <!doctype html>
      <html><head><link rel="canonical" href="#{LittleGhostDocs::SITE_URL}"></head><body>
      <header><a class="version-badge" href="https://rubygems.org">v#{version}</a></header>
      <main>LittleGhost</main></body></html>
    HTML
  end

  def docs_page(title, version)
    <<~HTML
      <!doctype html>
      <html><head><title>#{title}</title></head><body>
      <header><a class="navbar-version" href="https://rubygems.org">v#{version}</a></header>
      <main>#{title}</main></body></html>
    HTML
  end
end
