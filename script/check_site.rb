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

common_navigation_labels = %w[Home Docs GitHub]
common_navigation_pattern = /<nav\b[^>]*aria-label=["']Primary navigation["'][^>]*>(.*?)<\/nav>/mi
navigation_link_pattern = /<a\b([^>]*)>(.*?)<\/a>/mi

navigation_contract = lambda do |page, html, current_label|
  relative_page = page.relative_path_from(site_root)
  navigation = html[common_navigation_pattern, 1]

  if navigation.nil?
    errors << "#{relative_page} is missing primary navigation"
    next
  end

  links = navigation.scan(navigation_link_pattern).to_h do |attributes, content|
    label = CGI.unescapeHTML(content.gsub(/<[^>]+>/, " ")).split.join(" ")
    href = attributes[/\bhref=["']([^"']+)["']/i, 1]
    [label, {attributes:, href:}]
  end

  expected_targets = {
    "Home" => site_root.join("index.html"),
    "Docs" => site_root.join("docs/index.html")
  }

  expected_targets.each do |label, expected_target|
    link = links[label]
    errors << "#{relative_page} is missing #{label} navigation" and next unless link&.fetch(:href)

    path_reference = link.fetch(:href).partition("#").first.partition("?").first
    decoded_path = URI::DEFAULT_PARSER.unescape(path_reference)
    target = page.dirname.join(decoded_path).cleanpath
    target = target.join("index.html") if path_reference.end_with?("/")
    errors << "#{relative_page} has the wrong #{label} navigation target" unless target == expected_target
  end

  github = links["GitHub"]
  unless github&.fetch(:href) == "https://github.com/mattyr/little_ghost"
    errors << "#{relative_page} has the wrong GitHub navigation target"
  end

  common_navigation_labels.each do |label|
    link = links[label]
    next unless link

    is_current = link.fetch(:attributes).match?(/\baria-current=["']page["']/i)
    errors << "#{relative_page} has the wrong current navigation item" unless is_current == (label == current_label)
  end
end

navigation_contract.call(site_root.join("index.html"), index, "Home")

site_root.join("docs").glob("**/*.html").each do |page|
  navigation_contract.call(page, page.read, "Docs")
end

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
