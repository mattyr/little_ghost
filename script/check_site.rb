# frozen_string_literal: true

require "cgi"
require "pathname"
require "uri"

site_root = Pathname(ARGV.fetch(0, "_site")).expand_path
required_paths = [
  ".nojekyll",
  "index.html",
  "404.html",
  "assets/site.css",
  "assets/site.js",
  "assets/favicon.svg",
  "assets/social-card.png",
  "docs/index.html",
  "docs/docs/guides/Getting Started_md.html",
  "docs/docs/guides/Core Concepts_md.html"
]

errors = required_paths.filter_map do |relative_path|
  "Missing #{relative_path}" unless site_root.join(relative_path).file?
end

errors << "CNAME must not be published" if site_root.join("CNAME").exist?

index = site_root.join("index.html").read
errors << "Landing page is missing its canonical URL" unless index.include?('rel="canonical" href="https://mattyr.github.io/little_ghost/"')
errors << "Landing page is missing its social preview" unless index.include?('property="og:image" content="https://mattyr.github.io/little_ghost/assets/social-card.png"')
errors << "Landing page is missing its primary heading" unless index.match?(/<h1\b[^>]*>.*?<\/h1>/m)
errors << "Landing page is missing skip navigation" unless index.include?('href="#main"')

attribute_pattern = /\b(?:href|src)=["']([^"']+)["']/i
anchor_pattern = /\b(?:id|name)=["']([^"']+)["']/i
anchors_by_page = {}

anchor_targets = lambda do |page|
  anchors_by_page[page] ||= page.read.scan(anchor_pattern).flatten.each_with_object({}) do |anchor, targets|
    targets[CGI.unescapeHTML(anchor)] = true
  end
end

site_root.glob("**/*.html").each do |page|
  page.read.scan(attribute_pattern).flatten.each do |raw_reference|
    reference = CGI.unescapeHTML(raw_reference)
    next if reference.start_with?("data:")

    next if reference.match?(/\A[a-z][a-z0-9+.-]*:/i) || reference.start_with?("//")

    if reference.start_with?("/")
      errors << "#{page.relative_path_from(site_root)} uses root-relative URL #{raw_reference}"
      next
    end

    path_with_query, fragment = reference.split("#", 2)
    path_reference = path_with_query.partition("?").first
    decoded_path = URI::DEFAULT_PARSER.unescape(path_reference)
    target = decoded_path.empty? ? page : page.dirname.join(decoded_path).cleanpath
    target = target.join("index.html") if path_reference.end_with?("/")
    inside_site = target == site_root || target.to_s.start_with?("#{site_root}#{File::SEPARATOR}")

    unless inside_site
      errors << "#{page.relative_path_from(site_root)} links outside the site with #{raw_reference}"
      next
    end

    unless target.exist?
      errors << "#{page.relative_path_from(site_root)} links to missing #{raw_reference}"
      next
    end

    next if fragment.nil? || fragment.empty? || !target.file? || target.extname.downcase != ".html"

    decoded_fragment = URI::DEFAULT_PARSER.unescape(fragment)
    unless anchor_targets.call(target).key?(decoded_fragment)
      errors << "#{page.relative_path_from(site_root)} links to missing anchor #{raw_reference}"
    end
  end
end

abort errors.join("\n") unless errors.empty?

puts "Verified #{site_root.glob("**/*.html").size} HTML pages and all local links."
