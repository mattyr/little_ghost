# frozen_string_literal: true

require "test_helper"
require_relative "../rakelib/little_ghost_docs"

class LittleGhostDocsTest < Minitest::Test
  def test_snapshot_adds_edge_selector_assets_and_catalog_location
    Dir.mktmpdir("little-ghost-docs") do |directory|
      site = build_site(directory, "site", version: "0.3.0")

      LittleGhostDocs::Snapshot.new(site, id: "edge", base_path: "").decorate!

      homepage = File.read(File.join(site, "index.html"))
      agent = File.read(File.join(site, "docs", "LittleGhost", "Agent.html"))
      assert_includes homepage, 'data-current-version="edge"'
      assert_includes homepage, 'data-versions-url="versions.json"'
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

  def test_archive_keeps_edge_mutable_and_release_snapshots_immutable
    Dir.mktmpdir("little-ghost-docs") do |directory|
      archive = File.join(directory, "archive")
      edge = build_site(directory, "edge", version: "0.4.0", pages: %w[Agent Assembly])
      release = build_site(directory, "release", version: "0.3.0", pages: %w[Agent])
      docs = LittleGhostDocs::Archive.new(archive)

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
      docs = LittleGhostDocs::Archive.new(archive)
      docs.publish_edge!(build_site(directory, "edge", version: "0.4.0"))
      docs.publish_release!(build_site(directory, "older", version: "0.1.0"), "0.1.0")
      docs.publish_release!(build_site(directory, "newer", version: "0.3.0"), "0.3.0")
      FileUtils.mkdir_p(File.join(archive, "versions", "notes"))
      LittleGhostDocs::Catalog.new(archive).write!

      catalog = JSON.parse(File.read(File.join(archive, "versions.json")))
      assert_equal %w[edge 0.3.0 0.1.0], catalog.fetch("versions").map { |entry| entry.fetch("id") }
    end
  end

  def test_archive_rejects_prerelease_versions
    Dir.mktmpdir("little-ghost-docs") do |directory|
      archive = LittleGhostDocs::Archive.new(File.join(directory, "archive"))
      site = build_site(directory, "site", version: "0.4.0.pre")

      error = assert_raises(LittleGhostDocs::Error) do
        archive.publish_release!(site, "0.4.0.pre")
      end
      assert_equal "Documentation releases must use stable versions", error.message
    end
  end

  def test_archive_preserves_assets_from_an_already_decorated_release
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
      LittleGhostDocs::Archive.new(archive, asset_source: current_assets).publish_release!(release, "1.0.0")

      assert_equal "release assets", File.read(File.join(archive, "versions", "1.0.0", "assets", "version-selector.js"))
    end
  end

  def test_release_merge_rejects_versions_missing_from_the_verified_candidate
    Dir.mktmpdir("little-ghost-docs") do |directory|
      published = File.join(directory, "published")
      candidate = File.join(directory, "candidate")
      published_archive = LittleGhostDocs::Archive.new(published)
      candidate_archive = LittleGhostDocs::Archive.new(candidate)
      published_archive.publish_edge!(build_site(directory, "published-edge", version: "2.0.0"))
      candidate_archive.publish_edge!(build_site(directory, "candidate-edge", version: "2.0.0"))
      published_archive.publish_release!(build_site(directory, "unknown", version: "9.0.0"), "9.0.0")
      candidate_archive.publish_release!(build_site(directory, "known", version: "1.0.0"), "1.0.0")

      error = assert_raises(LittleGhostDocs::Error) do
        published_archive.merge_releases!(candidate)
      end
      assert_equal "Documentation archive contains unverified releases: 9.0.0", error.message
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
        LittleGhostDocs::Archive.new(unmarked).publish_edge!(site)
      end
      assert_includes error.message, LittleGhostDocs::ARCHIVE_MARKER
      assert_equal "safe", File.read(sentinel)

      error = assert_raises(LittleGhostDocs::Error) do
        LittleGhostDocs::Archive.new(site).publish_edge!(site)
      end
      assert_equal "Documentation archive source cannot overlap its destination", error.message
    end
  end

  def test_workflows_publish_edge_and_stable_versions_through_the_shared_archive
    docs_workflow = File.read(File.expand_path("../.github/workflows/docs.yml", __dir__))
    release_workflow = File.read(File.expand_path("../.github/workflows/release.yml", __dir__))

    assert_includes docs_workflow, "workflow_run:"
    assert_includes docs_workflow, "github.ref == 'refs/heads/main'"
    assert_includes docs_workflow, "publish-edge _docs_archive _site"
    assert_includes docs_workflow, "publish-edge _published _candidate/edge"
    assert_includes docs_workflow, "merge-releases _published _candidate/archive"
    assert_includes docs_workflow, "sync-release _docs_archive"
    assert_includes docs_workflow, "does not have an annotated commit tag"
    assert_includes docs_workflow, "git merge-base --is-ancestor"
    assert_includes docs_workflow, "A newer main commit superseded this Edge build"
    assert_includes docs_workflow, "little-ghost-documentation-publish"
    assert_includes release_workflow, "publish-release _docs_archive _release_site"
    assert_includes release_workflow, "needs.publish.outputs.prerelease != 'true'"
    assert_includes release_workflow, "release-documentation.tgz"
    assert_includes release_workflow, "/versions/${version}/docs/"
  end

  private

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
