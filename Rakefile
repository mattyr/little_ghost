# frozen_string_literal: true

require "cgi"
require "erb"
require "pathname"
require "bundler/gem_tasks"
require "rake/testtask"
require "rdoc/rdoc"
require "rdoc/task"
require "uri"
require "webrick"

require_relative "lib/little_ghost/version"

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

RDOC_TITLE = "LittleGhost Docs"
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
  GUIDE_PATHS = {
    "docs/guides/core_concepts.md" => "core_concepts.html",
    "docs/guides/getting_started.md" => "getting_started.html"
  }.freeze
  LEGACY_GUIDE_LINKS = {
    %r{(?:docs/guides/)?core_concepts_md\.html} => "core_concepts.html",
    %r{(?:docs/guides/)?getting_started_md\.html} => "getting_started.html"
  }.freeze
  ALIKI_TEMPLATE = Pathname.new(
    File.join(File.dirname(RDoc::Generator::Aliki.instance_method(:initialize).source_location.first), "template", "aliki")
  ).freeze
  TEMPLATE_ROOT = Pathname.new(File.expand_path("site/rdoc", __dir__)).freeze
  CUSTOM_TEMPLATES = %w[_header.rhtml _sidebar_pages.rhtml].to_h do |file_name|
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
      file.define_singleton_method(:http_url) { path } if path
    end
  end

  def generate
    super
    rewrite_guide_links
  end

  private

  def rewrite_guide_links
    @outputdir.glob("**/*.html").each do |page|
      html = page.read
      rewritten = LEGACY_GUIDE_LINKS.reduce(html) do |content, (legacy_path, clean_path)|
        relative_path = @outputdir.join(clean_path).relative_path_from(page.dirname)
        content.gsub(legacy_path, relative_path.to_s)
      end
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
    "assets/favicon.svg",
    "assets/social-card.png",
    "docs/index.html",
    "docs/getting_started.html",
    "docs/core_concepts.html"
  ].freeze
  COMMON_NAVIGATION_LABELS = %w[Home Docs GitHub].freeze
  GUIDE_NAVIGATION_LABELS = ["Core Concepts", "Getting Started"].freeze
  COMMON_NAVIGATION_PATTERN = /<nav\b[^>]*aria-label=["']Primary navigation["'][^>]*>(.*?)<\/nav>/mi
  NAVIGATION_LINK_PATTERN = /<a\b([^>]*)>(.*?)<\/a>/mi
  ATTRIBUTE_PATTERN = /\b(?:href|src)=["']([^"']+)["']/i
  ANCHOR_PATTERN = /\b(?:id|name)=["']([^"']+)["']/i
  LEGACY_GUIDE_REFERENCE_PATTERN = /(?:Core%20Concepts|Getting%20Started|_md\.html)/

  def initialize(root)
    @site_root = Pathname(root).expand_path
    @errors = []
    @anchors_by_page = {}
  end

  def check
    check_required_paths
    check_landing_page
    check_documentation_navigation
    check_local_links

    abort errors.join("\n") unless errors.empty?

    puts "Verified #{site_root.glob("**/*.html").size} HTML pages and all local links."
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

    unless html.include?('rel="canonical" href="https://mattyr.github.io/little_ghost/"')
      errors << "Landing page is missing its canonical URL"
    end
    unless html.include?('property="og:image" content="https://mattyr.github.io/little_ghost/assets/social-card.png"')
      errors << "Landing page is missing its social preview"
    end

    errors << "Landing page is missing its primary heading" unless html.match?(/<h1\b[^>]*>.*?<\/h1>/m)
    errors << "Landing page is missing skip navigation" unless html.include?('href="#main"')
    check_version(page, html)
    check_navigation(page, html, "Home")
  end

  def check_documentation_navigation
    site_root.join("docs").glob("**/*.html").each do |page|
      html = page.read
      check_version(page, html)
      check_navigation(page, html, "Docs")
      errors << "#{page.relative_path_from(site_root)} is missing Docs home navigation" unless html.include?(">Docs home</a>")
      GUIDE_NAVIGATION_LABELS.each do |label|
        unless html.match?(/>\s*#{Regexp.escape(label)}\s*<\/a>/)
          errors << "#{page.relative_path_from(site_root)} is missing the #{label} guide navigation"
        end
      end
      if html.match?(/<summary>\s*docs\s*(?:<|$)/mi)
        errors << "#{page.relative_path_from(site_root)} nests guides under docs navigation"
      end
    end
  end

  def check_version(page, html)
    relative_page = page.relative_path_from(site_root)
    version = LittleGhost::VERSION
    expected_link = "https://rubygems.org/gems/little_ghost/versions/#{version}"

    errors << "#{relative_page} is missing version v#{version}" unless html.include?(">v#{version}<")
    errors << "#{relative_page} has the wrong RubyGems version link" unless html.include?(%(href="#{expected_link}"))
  end

  def check_navigation(page, html, current_label)
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

    check_local_navigation_target(page, relative_page, links, "Home", site_root.join("index.html"))
    check_local_navigation_target(page, relative_page, links, "Docs", site_root.join("docs/index.html"))

    unless links.dig("GitHub", :href) == "https://github.com/mattyr/little_ghost"
      errors << "#{relative_page} has the wrong GitHub navigation target"
    end

    COMMON_NAVIGATION_LABELS.each do |label|
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

  def inside_site?(target)
    target == site_root || target.to_s.start_with?("#{site_root}#{File::SEPARATOR}")
  end

  def anchor_targets(page)
    anchors_by_page[page] ||= page.read.scan(ANCHOR_PATTERN).flatten.each_with_object({}) do |anchor, targets|
      targets[CGI.unescapeHTML(anchor)] = true
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
    static_files = FileList["#{SITE_SOURCE}/*"].exclude(SITE_TEMPLATE_ROOT, "#{SITE_SOURCE}/index.html")
    cp_r static_files.to_a, SITE_OUTPUT
    homepage = ERB.new(File.read("#{SITE_SOURCE}/index.html"), trim_mode: "-")
    File.write("#{SITE_OUTPUT}/index.html", homepage.result)
    touch "#{SITE_OUTPUT}/.nojekyll"

    RDoc::RDoc.new.document([
      "--format", RDOC_GENERATOR,
      "--op", "#{SITE_OUTPUT}/docs",
      "--title", RDOC_TITLE,
      "--main", RDOC_MAIN,
      *RDOC_OPTIONS,
      *FileList[*RDOC_FILES].to_a
    ])
  end

  desc "Build and verify the complete GitHub Pages artifact"
  task check: :build do
    LittleGhostSiteChecker.new(SITE_OUTPUT).check
  end

  desc "Build and serve the site locally"
  task serve: :build do
    port = Integer(ENV.fetch("PORT", "4000"), 10)
    root = File.expand_path(SITE_OUTPUT, __dir__)
    server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: port
    )
    server.mount "/", LittleGhostSiteFileHandler, root, FancyIndexing: false
    %w[INT TERM].each { |signal| Signal.trap(signal) { server.shutdown } }

    puts "Serving #{SITE_OUTPUT} at http://127.0.0.1:#{port}/"
    server.start
  end
end

task default: :test
