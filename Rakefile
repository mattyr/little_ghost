# frozen_string_literal: true

require "cgi"
require "erb"
require "pathname"
require "ripper"
require "bundler/gem_tasks"
require "rake/testtask"
require "rdoc/rdoc"
require "rdoc/task"
require "uri"
require "webrick"

require_relative "lib/little_ghost/version"
require_relative "rakelib/little_ghost_docs"
require_relative "rakelib/little_ghost_markdown"

task "release:trusted_publishing_guard" do
  expected_ref = "refs/tags/v#{LittleGhost::VERSION}"
  trusted_workflow = ENV["GITHUB_ACTIONS"] == "true" &&
    ENV["GITHUB_REF"] == expected_ref &&
    ENV["LITTLEGHOST_TRUSTED_PUBLISHING"] == "true"
  abort "Direct gem publishing is disabled. Follow RELEASING.md and push a version tag." unless trusted_workflow
end

%w[release release:source_control_push release:rubygem_push].each do |task_name|
  Rake::Task[task_name].prerequisites.unshift("release:trusted_publishing_guard")
end
Rake::Task["release"].clear_comments
Rake::Task["release"].add_description("Publish through the trusted tag-triggered GitHub Actions workflow")

RDOC_TITLE = "LittleGhost API Documentation"
RDOC_GENERATOR = "littleghost"
RDOC_MAIN = "README.md"
RDOC_FILES = ["README.md", "docs/guides/*.md", "lib/**/*.rb"].freeze
RDOC_OPTIONS = [
  "--encoding", "UTF-8",
  "--visibility", "public",
  "--template-stylesheets", "site/assets/docs.css",
  "--warn-missing-rdoc-ref"
].freeze
SITE_SOURCE = "site"
SITE_OUTPUT = "_site"
SITE_TEMPLATE_ROOT = "#{SITE_SOURCE}/rdoc"

class RDoc::Generator::LittleGhost < RDoc::Generator::Aliki
  DESCRIPTION = "Aliki with LittleGhost navigation"
  GUIDE_PATHS = LittleGhostDocs::GUIDE_PATHS
  GUIDE_TITLES = LittleGhostDocs::GUIDE_TITLES
  GUIDE_SECTIONS = LittleGhostDocs::GUIDE_SECTIONS
  LEGACY_GUIDE_LINKS = GUIDE_PATHS.to_h do |source, output|
    basename = File.basename(source, ".md")
    [%r{(?:docs/guides/)?#{Regexp.escape(basename)}_md\.html}, output]
  end.freeze
  ALIKI_TEMPLATE = Pathname.new(
    File.join(File.dirname(RDoc::Generator::Aliki.instance_method(:initialize).source_location.first), "template", "aliki")
  ).freeze
  TEMPLATE_ROOT = Pathname.new(File.expand_path("site/rdoc", __dir__)).freeze
  FAVICON_SOURCE = Pathname.new(File.expand_path("site/assets/favicon.svg", __dir__)).freeze
  CUSTOM_TEMPLATES = %w[_footer.rhtml _header.rhtml _sidebar_classes.rhtml _sidebar_pages.rhtml].to_h do |file_name|
    [file_name, TEMPLATE_ROOT.join(file_name)]
  end.freeze

  RDoc::RDoc.add_generator self

  def initialize(store, options)
    options.template_dir ||= ALIKI_TEMPLATE.to_s
    super
  end

  def render(file_name)
    template_path = CUSTOM_TEMPLATES[file_name]
    return super unless template_path

    template = template_for(template_path, false, RDoc::ERBPartial)
    template.filename = template_path.to_s
    template.result(@context)
  end

  def refresh_store_data
    super

    @files.each do |file|
      path = GUIDE_PATHS[file.full_name]
      next unless path

      title = GUIDE_TITLES.fetch(file.full_name)
      file.define_singleton_method(:http_url) { path }
      file.define_singleton_method(:page_name) { title }
    end
  end

  def generate
    super
    @outputdir.join("favicon.svg").binwrite(FAVICON_SOURCE.binread)
    rewrite_output
  end

  def generate_ancestor_list(ancestors, klass)
    return "" if ancestors.empty?

    ancestor = ancestors.shift
    target = little_ghost_ancestor(ancestor, klass)
    label = CGI.escapeHTML(ancestor.respond_to?(:full_name) ? ancestor.full_name : ancestor.to_s)
    content = +"<ul><li>"
    content << if target
      %(<a href="#{klass.aref_to(target.path)}">#{label}</a>)
    else
      label
    end
    content << generate_ancestor_list(ancestors, klass)
    content << "</li></ul>"
  end

  private

  def little_ghost_ancestor(ancestor, klass)
    if ancestor.respond_to?(:full_name) && ancestor.full_name.start_with?("LittleGhost::")
      return ancestor
    end

    name = ancestor.to_s
    namespaces = klass.full_name.split("::")[0...-1]
    while namespaces.any?
      candidate = @store.find_class_or_module("#{namespaces.join("::")}::#{name}")
      return candidate if candidate&.full_name&.start_with?("LittleGhost::")

      namespaces.pop
    end
    nil
  end

  def rewrite_output
    @outputdir.glob("**/*.html").each do |page|
      html = page.read
      rewritten = LEGACY_GUIDE_LINKS.reduce(html) do |content, (legacy_path, clean_path)|
        relative_path = @outputdir.join(clean_path).relative_path_from(page.dirname)
        content.gsub(legacy_path, relative_path.to_s)
      end
      favicon_path = @outputdir.join("favicon.svg").relative_path_from(page.dirname)
      rewritten = rewritten.sub(
        "</title>",
        %(</title>\n<link rel="icon" href="#{favicon_path}" type="image/svg+xml">)
      )
      page.write(rewritten) unless rewritten == html
    end
  end
end

class LittleGhostSiteChecker
  REQUIRED_PATHS = [
    ".nojekyll",
    "index.html",
    "404.html",
    "assets/site.css",
    "assets/site.js",
    "assets/version-selector.css",
    "assets/version-selector.js",
    "assets/favicon.svg",
    "assets/social-card.png",
    "versions.json",
    "robots.txt",
    "llms.txt",
    "llms-full.txt",
    "index.md",
    "docs/index.html",
    "docs/index.md",
    "docs/api.html",
    "docs/api.md",
    "docs/favicon.svg",
    "docs/getting_started.html",
    "docs/prompt_views.html",
    "docs/core_concepts.html",
    "docs/models_and_providers.html",
    "docs/structured_outputs_and_content.html",
    "docs/assemblies.html",
    "docs/tools.html",
    "docs/skills.html",
    "docs/sandboxing.html",
    "docs/code_mode.html",
    "docs/integrations.html",
    "docs/production.html"
  ].freeze
  LANDING_NAVIGATION_LABELS = %w[Docs GitHub].freeze
  DOCUMENTATION_NAVIGATION_LABELS = %w[Home Docs GitHub].freeze
  GUIDE_NAVIGATION_LABELS = LittleGhostDocs::GUIDES.map { |guide| guide.fetch(:title) }.freeze
  ESSENTIAL_API_LABELS = %w[Agent Tool Run Assembly Workflow Swarm Graph].freeze
  RUBY_EXAMPLE_PATHS = [RDOC_MAIN, *RDoc::Generator::LittleGhost::GUIDE_PATHS.keys].freeze
  COMMON_NAVIGATION_PATTERN = /<nav\b[^>]*aria-label=["']Primary navigation["'][^>]*>(.*?)<\/nav>/mi
  NAVIGATION_LINK_PATTERN = /<a\b([^>]*)>(.*?)<\/a>/mi
  ATTRIBUTE_PATTERN = /\b(?:href|src)=["']([^"']+)["']/i
  ANCHOR_PATTERN = /\b(?:id|name)=["']([^"']+)["']/i
  LEGACY_GUIDE_REFERENCE_PATTERN = /(?:Core%20Concepts|Code%20Mode|Getting%20Started|Prompts%20as%20Views|Compose%20Agents|Workspaces%2C%20Sandboxes%2C%20and%20Tools|Running%20in%20Production|_md\.html)/
  MODIFIED_THEME_CREDIT = "using a modified version of the Aliki theme by"

  def initialize(root)
    @site_root = Pathname(root).expand_path
    @errors = []
    @anchors_by_page = {}
  end

  def check
    check_required_paths
    check_landing_page
    check_getting_started_page
    check_api_index_metadata
    check_documentation_navigation
    check_local_links
    check_markdown_surface
    check_discovery_files
    check_ruby_examples

    abort errors.join("\n") unless errors.empty?

    puts "Verified #{site_root.glob("**/*.html").size} HTML pages, #{site_root.glob("**/*.md").size} Markdown pages, and all local links."
  end

  private

  attr_reader :anchors_by_page, :errors, :site_root

  def check_required_paths
    REQUIRED_PATHS.each do |relative_path|
      errors << "Missing #{relative_path}" unless site_root.join(relative_path).file?
    end

    errors << "CNAME must not be published" if site_root.join("CNAME").exist?
    errors << "RDoc templates must not be published" if site_root.glob("**/*.rhtml").any?
    errors << "Legacy RDoc guide pages must not be published" if site_root.glob("docs/**/*_md.html").any?
  end

  def check_landing_page
    page = site_root.join("index.html")
    html = page.read

    unless html.include?(%(rel="canonical" href="#{LittleGhostDocs::SITE_URL}"))
      errors << "Landing page is missing its canonical URL"
    end
    social_image = URI.join(LittleGhostDocs::SITE_URL, "assets/social-card.png").to_s
    unless html.include?(%(property="og:image" content="#{social_image}"))
      errors << "Landing page is missing its social preview"
    end

    errors << "Landing page is missing its primary heading" unless html.match?(/<h1\b[^>]*>.*?<\/h1>/m)
    errors << "Landing page is missing skip navigation" unless html.include?('href="#main"')
    errors << "Landing page is missing the single-agent demo" unless html.include?('id="first-agent"') && html.include?('data-demo="agent"')
    errors << "Landing page is missing the agent-graph demo" unless html.include?('id="agent-graph"') && html.include?('data-demo="graph"')
    errors << "Landing page is missing the batteries section" unless html.include?('id="batteries"')
    unless html.include?("CustomerSupportAgent") && html.include?("BookClubLaunchGraph")
      errors << "Landing page is missing its Agent or Graph example"
    end
    if html.match?(/Docker backends|Move from bind mounts|direct_tools/)
      errors << "Landing page contains obsolete sandbox or code-mode guidance"
    end
    unless html.include?("Seatbelt on macOS or Bubblewrap on Linux")
      errors << "Landing page does not describe the native sandbox backend"
    end
    check_version(page, html)
    check_navigation(page, html, LANDING_NAVIGATION_LABELS)
  end

  def check_getting_started_page
    html = site_root.join("docs/getting_started.html").read
    return if html.include?("OPENROUTER_API_KEY")

    errors << "Getting Started does not state the first Agent's credential prerequisite"
  end

  def check_api_index_metadata
    page = site_root.join("docs/api.html")
    return unless page.file?

    html = page.read
    title = LittleGhostDocs::MarkdownSite::API_INDEX_TITLE
    description = CGI.escapeHTML(LittleGhostDocs::MarkdownSite::API_INDEX_DESCRIPTION)
    errors << "API index has the wrong description metadata" unless html.include?(%(name="description" content="#{description}"))
    errors << "API index has the wrong Open Graph title" unless html.include?(%(property="og:title" content="#{title}"))
    errors << "API index has the wrong Open Graph description" unless html.include?(%(property="og:description" content="#{description}"))
    errors << "API index has the wrong Twitter title" unless html.include?(%(name="twitter:title" content="#{title}"))
    errors << "API index has the wrong Twitter description" unless html.include?(%(name="twitter:description" content="#{description}"))
  end

  def check_documentation_navigation
    site_root.join("docs").glob("**/*.html").each do |page|
      html = page.read
      check_version(page, html)
      check_navigation(page, html, DOCUMENTATION_NAVIGATION_LABELS, current_label: "Docs")
      errors << "#{page.relative_path_from(site_root)} is missing Docs home navigation" unless html.include?(">Docs home</a>")
      file_index = html[/<div id=["']fileindex-section["'].*?<\/div>/m]
      if file_index&.match?(/<details\b|>\s*Pages\s*</m)
        errors << "#{page.relative_path_from(site_root)} hides guide navigation behind a Pages section"
      end
      unless html.include?(MODIFIED_THEME_CREDIT)
        errors << "#{page.relative_path_from(site_root)} is missing the modified Aliki theme credit"
      end
      GUIDE_NAVIGATION_LABELS.each do |label|
        unless html.match?(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
          errors << "#{page.relative_path_from(site_root)} is missing the #{label} guide navigation"
        end
      end
      RDoc::Generator::LittleGhost::GUIDE_SECTIONS.each do |section, paths|
        section_content = file_index&.match(
          /<h2>\s*#{Regexp.escape(section)}\s*<\/h2>(.*?)(?=<h2>|\z)/m
        )&.captures&.first
        unless section_content
          errors << "#{page.relative_path_from(site_root)} is missing the #{section} guide section"
          next
        end

        expected_labels = paths.map { |path| RDoc::Generator::LittleGhost::GUIDE_TITLES.fetch(path) }
        expected_labels.each do |label|
          unless section_content.match?(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
            errors << "#{page.relative_path_from(site_root)} has #{label} outside the #{section} guide section"
          end
        end
        (GUIDE_NAVIGATION_LABELS - expected_labels).each do |label|
          if section_content.match?(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
            errors << "#{page.relative_path_from(site_root)} unexpectedly has #{label} in the #{section} guide section"
          end
        end
      end
      guide_positions = GUIDE_NAVIGATION_LABELS.filter_map do |label|
        html.index(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
      end
      if guide_positions.length == GUIDE_NAVIGATION_LABELS.length && guide_positions != guide_positions.sort
        errors << "#{page.relative_path_from(site_root)} has guides in the wrong learning order"
      end
      if html.match?(/<summary>\s*docs\s*(?:<|$)/mi)
        errors << "#{page.relative_path_from(site_root)} nests guides under docs navigation"
      end
      essential_api = html[/<div id=["']essential-api-section["'].*?<\/div>/m]
      unless essential_api
        errors << "#{page.relative_path_from(site_root)} is missing Essential API navigation"
        next
      end
      ESSENTIAL_API_LABELS.each do |label|
        unless essential_api.match?(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
          errors << "#{page.relative_path_from(site_root)} is missing the #{label} API shortcut"
        end
      end
    end
  end

  def check_version(page, html)
    relative_page = page.relative_path_from(site_root)
    unless html.include?("data-docs-version-picker") && html.include?('data-current-version="edge"')
      errors << "#{relative_page} is missing the Edge documentation selector"
    end
  end

  def check_navigation(page, html, required_labels, current_label: nil)
    relative_page = page.relative_path_from(site_root)
    navigation = html[COMMON_NAVIGATION_PATTERN, 1]

    unless navigation
      errors << "#{relative_page} is missing primary navigation"
      return
    end

    links = navigation.scan(NAVIGATION_LINK_PATTERN).to_h do |attributes, content|
      label = CGI.unescapeHTML(content.gsub(/<[^>]+>/, " ")).split.join(" ")
      href = attributes[/\bhref=["']([^"']+)["']/i, 1]
      [label, {attributes:, href:}]
    end

    (DOCUMENTATION_NAVIGATION_LABELS - required_labels).each do |label|
      errors << "#{relative_page} has unexpected #{label} navigation" if links.key?(label)
    end

    if required_labels.include?("Home")
      check_local_navigation_target(page, relative_page, links, "Home", site_root.join("index.html"))
    end
    if required_labels.include?("Docs")
      check_local_navigation_target(page, relative_page, links, "Docs", site_root.join("docs/index.html"))
    end

    if required_labels.include?("GitHub") && links.dig("GitHub", :href) != "https://github.com/mattyr/little_ghost"
      errors << "#{relative_page} has the wrong GitHub navigation target"
    end

    DOCUMENTATION_NAVIGATION_LABELS.each do |label|
      link = links[label]
      next unless link

      is_current = link.fetch(:attributes).match?(/\baria-current=["']page["']/i)
      errors << "#{relative_page} has the wrong current navigation item" unless is_current == (label == current_label)
    end
  end

  def check_local_navigation_target(page, relative_page, links, label, expected_target)
    href = links.dig(label, :href)

    unless href
      errors << "#{relative_page} is missing #{label} navigation"
      return
    end

    path_reference = href.partition("#").first.partition("?").first
    decoded_path = URI::DEFAULT_PARSER.unescape(path_reference)
    target = page.dirname.join(decoded_path).cleanpath
    target = target.join("index.html") if path_reference.end_with?("/")
    errors << "#{relative_page} has the wrong #{label} navigation target" unless target == expected_target
  end

  def check_local_links
    site_root.glob("**/*.html").each do |page|
      page.read.scan(ATTRIBUTE_PATTERN).flatten.each do |raw_reference|
        check_reference(page, raw_reference)
      end
    end
  end

  def check_markdown_surface
    site_root.glob("**/*.html").sort.each do |page|
      next if page.basename.to_s == "404.html"

      markdown = page.sub_ext(".md")
      relative_page = page.relative_path_from(site_root)
      unless markdown.file?
        errors << "#{relative_page} is missing its Markdown representation"
        next
      end

      html = page.read
      expected_canonical = canonical_url(relative_page)
      unless html.include?(%(<link rel="canonical" href="#{expected_canonical}">))
        errors << "#{relative_page} is missing canonical URL #{expected_canonical}"
      end
      check_version_local_public_urls(page, html)
      expected_url = "#{LittleGhostDocs::SITE_URL}#{markdown.relative_path_from(site_root)}"
      unless html.include?(%(<link rel="alternate" type="text/markdown" href="#{expected_url}">))
        errors << "#{relative_page} is missing its Markdown alternate"
      end
      unless html.include?(%(class="docs-markdown-link visually-hidden")) &&
          html.include?(%(href="#{expected_url}" aria-hidden="true"))
        errors << "#{relative_page} is missing its hidden Markdown pointer"
      end
    end

    site_root.glob("**/*.md").sort.each do |page|
      relative_page = page.relative_path_from(site_root)
      source = page.read
      errors << "#{relative_page} contains an unresolved rdoc-ref" if source.include?("rdoc-ref:")
      check_version_local_public_urls(page, source)
      check_markdown_links(page, source)
    end
  end

  def check_markdown_links(page, source)
    source.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.each do |raw_reference|
      reference = raw_reference.split(/\s+["']/).first
      next if reference.match?(/\A[a-z][a-z0-9+.-]*:/i) || reference.start_with?("#")

      path_reference, fragment = reference.split("#", 2)
      target = if path_reference.empty?
        page
      else
        page.dirname.join(URI::RFC2396_PARSER.unescape(path_reference)).cleanpath
      end
      unless inside_site?(target) && target.file?
        errors << "#{page.relative_path_from(site_root)} links to missing #{raw_reference}"
        next
      end
      next unless fragment && !fragment.empty?

      decoded_fragment = URI::RFC2396_PARSER.unescape(fragment)
      unless LittleGhostDocs.markdown_anchors(target.read).key?(decoded_fragment)
        errors << "#{page.relative_path_from(site_root)} links to missing anchor #{raw_reference}"
      end
    end
  end

  def canonical_url(relative_page)
    if relative_page.basename.to_s == "index.html"
      directory = relative_page.dirname.to_s
      directory = "" if directory == "."
      directory = "#{directory}/" unless directory.empty?
      URI.join(LittleGhostDocs::SITE_URL, directory).to_s
    else
      URI.join(LittleGhostDocs::SITE_URL, relative_page.to_s).to_s
    end
  end

  def check_version_local_public_urls(page, contents)
    relative_page = page.relative_path_from(site_root)
    match = relative_page.to_s.match(%r{\Aversions/([^/]+)/})
    return unless match

    site_path = URI(LittleGhostDocs::SITE_URL).path
    expected_prefix = "#{site_path}versions/#{match[1]}/"
    contents.scan(LittleGhostDocs::PUBLIC_DOCUMENTATION_URL_PATTERN).each do |url|
      path = URI(url).path
      next if path == "#{site_path}versions.json" || path.start_with?(expected_prefix)

      errors << "#{relative_page} links outside its documentation version with #{url}"
    end
  end

  def check_discovery_files
    snapshots = [[site_root, LittleGhostDocs::EDGE_ID]]
    versions_root = site_root.join(LittleGhostDocs::VERSION_DIRECTORY)
    if versions_root.directory?
      versions_root.children.select(&:directory?).each do |directory|
        snapshots << [directory, directory.basename.to_s]
      end
    end

    snapshots.each do |root, version|
      %w[llms.txt llms-full.txt].each do |file_name|
        path = root.join(file_name)
        errors << "Documentation #{version} is missing #{file_name}" unless path.file?
      end
      next unless root.join("llms.txt").file?

      root.join("llms.txt").read.scan(LittleGhostDocs::PUBLIC_DOCUMENTATION_URL_PATTERN).each do |url|
        uri = URI(url)
        site_path = URI(LittleGhostDocs::SITE_URL).path
        next if uri.path == "#{site_path}versions.json"

        relative_path = uri.path.delete_prefix(site_path)
        target = site_root.join(relative_path)
        errors << "Documentation #{version} discovery links to missing #{url}" unless target.file?
      end
      if version != LittleGhostDocs::EDGE_ID && root.join("llms-full.txt").read.include?("Documentation version: Edge")
        errors << "Documentation #{version} full text contains Edge content"
      end
    end
  end

  def check_reference(page, raw_reference)
    reference = CGI.unescapeHTML(raw_reference)
    if reference.match?(LEGACY_GUIDE_REFERENCE_PATTERN)
      errors << "#{page.relative_path_from(site_root)} uses legacy guide URL #{raw_reference}"
      return
    end

    return if reference.start_with?("data:")
    return if reference.match?(/\A[a-z][a-z0-9+.-]*:/i) || reference.start_with?("//")

    relative_page = page.relative_path_from(site_root)
    if reference.start_with?("/")
      errors << "#{relative_page} uses root-relative URL #{raw_reference}"
      return
    end

    path_with_query, fragment = reference.split("#", 2)
    path_reference = path_with_query.partition("?").first
    decoded_path = URI::DEFAULT_PARSER.unescape(path_reference)
    target = decoded_path.empty? ? page : page.dirname.join(decoded_path).cleanpath
    target = target.join("index.html") if path_reference.end_with?("/")

    unless inside_site?(target)
      errors << "#{relative_page} links outside the site with #{raw_reference}"
      return
    end

    unless target.exist?
      errors << "#{relative_page} links to missing #{raw_reference}"
      return
    end

    return unless fragment && !fragment.empty? && target.file? && target.extname.downcase == ".html"

    decoded_fragment = URI::DEFAULT_PARSER.unescape(fragment)
    unless anchor_targets(target).key?(decoded_fragment)
      errors << "#{relative_page} links to missing anchor #{raw_reference}"
    end
  end

  def check_ruby_examples
    RUBY_EXAMPLE_PATHS.each do |relative_path|
      path = Pathname(__dir__).join(relative_path)
      source = path.read
      source.to_enum(:scan, /^```ruby[^\n]*\n(.*?)^```\s*$/m).each do
        match = Regexp.last_match
        code = match[1]
        first_line = source.byteslice(0, match.begin(1)).count("\n") + 1
        parser = RubyExampleParser.new(code, relative_path, first_line)
        parser.parse
        parser.errors.each do |line, column, message|
          errors << "#{relative_path}:#{line}:#{column}: #{message}"
        end
      end
    end
  end

  def inside_site?(target)
    target == site_root || target.to_s.start_with?("#{site_root}#{File::SEPARATOR}")
  end

  def anchor_targets(page)
    anchors_by_page[page] ||= page.read.scan(ANCHOR_PATTERN).flatten.each_with_object({}) do |anchor, targets|
      targets[CGI.unescapeHTML(anchor)] = true
    end
  end

  class RubyExampleParser < Ripper
    attr_reader :errors

    def initialize(*)
      @errors = []
      super
    end

    def on_parse_error(message)
      errors << [lineno, column, message]
    end
  end
end

class LittleGhostSiteFileHandler < WEBrick::HTTPServlet::FileHandler
  def initialize(server, root, options = {})
    super
    @not_found_page = Pathname(root).join("404.html")
  end

  def service(request, response)
    super
  rescue WEBrick::HTTPStatus::NotFound
    response.status = 404
    response["content-type"] = "text/html; charset=utf-8"
    response.body = @not_found_page.binread
  end
end

class LittleGhostSiteServer
  def self.start(root:, port:, label: root)
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: port
    )
    server.mount "/", LittleGhostSiteFileHandler, root, FancyIndexing: false
    %w[INT TERM].each { |signal| Signal.trap(signal) { server.shutdown } }

    puts "Serving #{label} at http://127.0.0.1:#{port}/"
    server.start
  end
end

Rake::TestTask.new do |task|
  task.libs << "lib"
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

RDoc::Task.new do |rdoc|
  rdoc.generator = RDOC_GENERATOR
  rdoc.title = RDOC_TITLE
  rdoc.main = RDOC_MAIN
  rdoc.rdoc_dir = "doc/rdoc"
  rdoc.rdoc_files.include(*RDOC_FILES)
  rdoc.options.concat(RDOC_OPTIONS)
end

namespace :site do
  desc "Build the GitHub Pages site and generated API documentation"
  task :build do
    rm_rf SITE_OUTPUT
    mkdir_p SITE_OUTPUT
    static_files = FileList["#{SITE_SOURCE}/*"].exclude(
      SITE_TEMPLATE_ROOT,
      "#{SITE_SOURCE}/index.html",
      "#{SITE_SOURCE}/release-compat"
    )
    cp_r static_files.to_a, SITE_OUTPUT
    homepage = ERB.new(File.read("#{SITE_SOURCE}/index.html"), trim_mode: "-")
    File.write("#{SITE_OUTPUT}/index.html", homepage.result)
    touch "#{SITE_OUTPUT}/.nojekyll"

    rdoc = RDoc::RDoc.new
    rdoc.document([
      "--format", RDOC_GENERATOR,
      "--op", "#{SITE_OUTPUT}/docs",
      "--title", RDOC_TITLE,
      "--main", RDOC_MAIN,
      *RDOC_OPTIONS,
      *FileList[*RDOC_FILES].to_a
    ])

    docs_id = ENV.fetch("DOCS_VERSION_ID", LittleGhostDocs::EDGE_ID)
    docs_base_path = ENV.fetch("DOCS_BASE_PATH", "")
    LittleGhostDocs::MarkdownSite.new(
      source_root: __dir__,
      site_root: SITE_OUTPUT,
      store: rdoc.store,
      id: docs_id,
      base_path: docs_base_path
    ).build!
    LittleGhostDocs::Snapshot.new(SITE_OUTPUT, id: docs_id, base_path: docs_base_path).decorate!
    LittleGhostDocs::Catalog.new(SITE_OUTPUT).write! if docs_id == LittleGhostDocs::EDGE_ID && docs_base_path.empty?
  end

  desc "Build and verify the complete GitHub Pages artifact"
  task check: :build do
    LittleGhostDocs::VersionedSite.new(SITE_OUTPUT).verify!
    LittleGhostSiteChecker.new(SITE_OUTPUT).check
  end

  desc "Build Edge and every published documentation version"
  task build_all: :build do
    repository = File.expand_path(__dir__)
    edge_site = File.expand_path(SITE_OUTPUT, __dir__)

    Dir.mktmpdir("little-ghost-versioned-site") do |destination|
      LittleGhostDocs::SiteBuilder.new(repository:, edge_site:).build!(destination)
      LittleGhostSiteChecker.new(destination).check
      rm_rf SITE_OUTPUT
      mkdir_p SITE_OUTPUT
      Pathname(destination).children.each { |child| cp_r child, SITE_OUTPUT }
    end
  end

  desc "Build and serve the site locally"
  task serve: :build do
    port = Integer(ENV.fetch("PORT", "4000"), 10)
    root = File.expand_path(SITE_OUTPUT, __dir__)
    LittleGhostSiteServer.start(root:, port:, label: SITE_OUTPUT)
  end

  desc "Build Edge with every published documentation version and serve them locally"
  task serve_all: :build_all do
    port = Integer(ENV.fetch("PORT", "4000"), 10)
    root = File.expand_path(SITE_OUTPUT, __dir__)
    LittleGhostSiteServer.start(root:, port:, label: "Edge and all published versions")
  end
end

task default: :test
