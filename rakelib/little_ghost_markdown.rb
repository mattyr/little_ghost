# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "pathname"
require "rdoc"
require "rdoc/cross_reference"
require "rdoc/markup/to_markdown"
require "rdoc/rdoc"
require "tmpdir"
require "uri"

module LittleGhostDocs
  class MarkdownSite
    API_INDEX_TITLE = "LittleGhost API index"
    API_INDEX_DESCRIPTION = "Browse LittleGhost's public classes, modules, methods, and signatures."

    BUILD_MUTEX = Mutex.new
    API_ROOT = Pathname("docs")
    ESSENTIAL_APIS = %w[
      LittleGhost
      LittleGhost/Agent
      LittleGhost/Tool
      LittleGhost/Run
      LittleGhost/Assembly
      LittleGhost/Workflow
      LittleGhost/Swarm
      LittleGhost/Graph
      LittleGhost/Configuration
      LittleGhost/Runtime
    ].freeze
    INTEGRATION_APIS = %w[
      LittleGhost/Skills/Catalog
      LittleGhost/MCP/Toolset
      LittleGhost/MCP/Client
      LittleGhost/MCP/HTTPTransport
      LittleGhost/AGUI/Adapter
      LittleGhost/Tracing/OpenTelemetry
    ].freeze

    def self.build_from_source(source_root:, site_root:, id:, base_path:)
      BUILD_MUTEX.synchronize do
        source_root = Pathname(source_root).expand_path
        store = parse_store(source_root)
        new(source_root:, site_root:, store:, id:, base_path:).build!
      end
    end

    def self.parse_store(source_root)
      Dir.mktmpdir("little-ghost-markdown-rdoc") do |directory|
        Dir.chdir(source_root) do
          files = ["README.md", *Dir["docs/guides/*.md"].sort, *Dir["lib/**/*.rb"].sort]
          rdoc = RDoc::RDoc.new
          rdoc.document([
            "--quiet",
            "--format", "ri",
            "--op", File.join(directory, "rdoc"),
            "--visibility", "public",
            *files
          ])
          return rdoc.store
        end
      end
    end
    private_class_method :parse_store

    def initialize(source_root:, site_root:, store:, id:, base_path:)
      @source_root = Pathname(source_root).expand_path
      @site_root = Pathname(site_root).expand_path
      @store = store
      @id = id.to_s
      @base_path = Pathname(base_path.to_s)
    end

    def build!
      raise Error, "Documentation source does not exist at #{source_root}" unless source_root.directory?
      raise Error, "Documentation site does not exist at #{site_root}" unless site_root.directory?

      write("index.md", homepage_markdown)
      write_docs_home
      write_guides
      write_api_pages
      write_api_index
      write_discovery_files
      self
    end

    private

    attr_reader :base_path, :id, :site_root, :source_root, :store

    def write_docs_home
      source = source_root.join("README.md")
      return unless source.file?

      output = Pathname("docs/index.md")
      write(output, source_document_markdown(
        source.read,
        title: "LittleGhost documentation",
        html_path: "docs/",
        output_path: output,
        context: rdoc_file("README.md")
      ))
    end

    def write_guides
      available_guides.each do |guide|
        source = source_root.join(guide.fetch(:source))
        output = Pathname("docs").join(Pathname(guide.fetch(:output)).sub_ext(".md"))
        write(output, source_document_markdown(
          source.read,
          title: guide.fetch(:title),
          html_path: output.sub_ext(".html"),
          output_path: output,
          context: rdoc_file(guide.fetch(:source))
        ))
      end
    end

    def write_api_pages
      api_objects.each do |object|
        output = API_ROOT.join(Pathname(object.path).sub_ext(".md"))
        write(output, api_markdown(object, output))
      end
    end

    def write_api_index
      output = Pathname("docs/api.md")
      lines = [document_header(API_INDEX_TITLE, "docs/api.html")]
      lines << "Every public class and module is listed here. Open an entry for signatures, ownership, and failure behavior.\n\n"
      api_objects.each do |object|
        target = API_ROOT.join(Pathname(object.path).sub_ext(".md"))
        relative = target.relative_path_from(output.dirname)
        lines << "- [#{object.full_name}](#{relative}) — #{summary_for(object)}\n"
      end
      write(output, lines.join)
      write_api_index_html
    end

    def write_api_index_html
      template = site_root.join("docs/index.html")
      return unless template.file?

      items = api_objects.map do |object|
        summary = CGI.escapeHTML(summary_for(object))
        %(<li><p><a href="#{object.path}"><code>#{CGI.escapeHTML(object.full_name)}</code></a> — #{summary}</p></li>)
      end.join
      content = <<~HTML
        <main role="main">
        <h1 id="littleghost-api-index"><a href="#littleghost-api-index">LittleGhost API index</a></h1>
        <p>Every public class and module is listed here. Open an entry for signatures, ownership, and failure behavior.</p>
        <ul>#{items}</ul>
        </main>
      HTML
      html = template.read.sub(/<main role="main">.*?<\/main>/m, content.rstrip)
      html = html.sub(/<title>.*?<\/title>/m, "<title>#{API_INDEX_TITLE} - LittleGhost API Documentation</title>")
      html = replace_meta(html, "name", "description", API_INDEX_DESCRIPTION)
      html = replace_meta(html, "property", "og:title", API_INDEX_TITLE)
      html = replace_meta(html, "property", "og:description", API_INDEX_DESCRIPTION)
      html = replace_meta(html, "name", "twitter:title", API_INDEX_TITLE)
      html = replace_meta(html, "name", "twitter:description", API_INDEX_DESCRIPTION)
      site_root.join("docs/api.html").write(html)
    end

    def replace_meta(html, attribute, key, content)
      tag = %(<meta #{attribute}="#{key}" content="#{CGI.escapeHTML(content)}">)
      pattern = %r{<meta\b(?=[^>]*\b#{attribute}=["']#{Regexp.escape(key)}["'])[^>]*>}m
      return html.sub(pattern, tag) if html.match?(pattern)

      html.sub("</head>", "#{tag}\n</head>")
    end

    def api_markdown(object, output)
      kind = object.is_a?(RDoc::NormalModule) ? "Module" : "Class"
      markdown = +document_header("#{kind} #{object.full_name}", API_ROOT.join(object.path))
      markdown << render_comment(object.comment, context: object, output_path: output)

      if !object.is_a?(RDoc::NormalModule) && object.superclass
        superclass = object.superclass.respond_to?(:full_name) ? object.superclass.full_name : object.superclass.to_s
        markdown << "\n## Inheritance\n\n`#{object.full_name} < #{superclass}`\n"
      end

      includes = object.includes.map(&:name).uniq.sort
      markdown << "\n## Includes\n\n#{includes.map { |name| "- `#{name}`" }.join("\n")}\n" unless includes.empty?

      constants = object.constants.select { |constant| visible?(constant) }.sort_by(&:name)
      unless constants.empty?
        markdown << "\n## Constants\n"
        constants.each do |constant|
          markdown << "\n### `#{constant.name}`\n\n"
          markdown << render_comment(constant.comment, context: object, output_path: output)
        end
      end

      attributes = object.attributes.select { |attribute| visible?(attribute) }.sort_by(&:name)
      unless attributes.empty?
        markdown << "\n## Attributes\n"
        attributes.each do |attribute|
          markdown << "\n<a id=\"#{anchor_from(attribute.path)}\"></a>\n"
          markdown << "### `#{attribute.name}` (#{attribute.rw})\n\n"
          markdown << render_comment(attribute.comment, context: object, output_path: output)
        end
      end

      methods = object.method_list.select { |method| visible?(method) && method.parent == object }
      [[true, "Class methods"], [false, "Instance methods"]].each do |singleton, heading|
        selected = methods.select { |method| method.singleton == singleton }.sort_by(&:name)
        next if selected.empty?

        markdown << "\n## #{heading}\n"
        selected.each do |method|
          markdown << "\n<a id=\"#{anchor_from(method.path)}\"></a>\n"
          markdown << "### `#{singleton ? "." : "#"}#{method.name}`\n\n"
          markdown << "```ruby\n#{method_signature(method)}\n```\n\n"
          markdown << render_comment(method.comment, context: object, output_path: output)
        end
      end

      normalize(markdown)
    end

    def homepage_markdown
      source = source_root.join("site/index.html")
      return document_header("LittleGhost", "index.html") + "LittleGhost documentation.\n" unless source.file?

      html = source.read
      intro = html[/<section class="home-intro".*?<p>(.*?)<\/p>/m, 1]
      agent = html[/<section class="demo-section" id="first-agent".*?<\/section>/m]
      graph = html[/<section class="demo-section" id="agent-graph".*?<\/section>/m]
      batteries = html[/<section class="batteries-section".*?<\/section>/m]
      markdown = +document_header("LittleGhost", "")
      markdown << "#{plain_text(intro)}\n\n" if intro
      markdown << "## Install\n\n```shell\nbundle add little_ghost\n```\n\nRuby 3.3 or newer is required.\n"
      markdown << homepage_demo("Your first agent", agent)
      markdown << homepage_demo("Grow your agent team", graph)
      if batteries
        markdown << "\n## Batteries included\n"
        batteries.scan(/<article\b.*?<h3>(.*?)<\/h3><p>(.*?)<\/p>.*?<\/article>/m).each do |title, description|
          markdown << "\n### #{plain_text(title)}\n\n#{plain_text(description)}\n"
        end
      end
      markdown << "\n## Continue\n\n- [Read the documentation](docs/index.md)\n- [Start with your first agent](docs/getting_started.md)\n- [Browse the public API](docs/api.md)\n- [Give your coding agent `#{public_url("llms.txt")}`](llms.txt)\n"
      normalize(markdown)
    end

    def homepage_demo(title, section)
      return "" unless section

      code = section.scan(/data-plain=(?:"([^"]*)"|'([^']*)')/m).map do |double, single|
        CGI.unescapeHTML(double || single)
      end.join("\n")
      "\n## #{title}\n\n```ruby\n#{code}\n```\n"
    end

    def write_discovery_files
      write("llms.txt", llms_text)
      write("llms-full.txt", llms_full_text)
    end

    def llms_text
      available = markdown_pages.to_h { |path| [path.relative_path_from(site_root).to_s, true] }
      guide_sections = GUIDE_SECTIONS.transform_values do |sources|
        sources.map { |source| "docs/#{Pathname(GUIDE_PATHS.fetch(source)).sub_ext(".md")}" }
      end
      sections = {"Start here" => ["docs/index.md", *guide_sections.delete("Learn")]}
      sections.merge!(guide_sections)
      sections["Essential API"] = ESSENTIAL_APIS.map { |path| "docs/#{path}.md" }
      sections["Integrations API"] = INTEGRATION_APIS.map { |path| "docs/#{path}.md" }
      text = +"# LittleGhost\n\n> An open-source Ruby 3.3+ library for agents, tools, workflows, swarms, and graphs.\n\n"
      text << "This documentation describes #{(id == EDGE_ID) ? "the Edge build" : "LittleGhost v#{id}"}. "
      text << "Use a matching release snapshot for an application pinned to a released gem.\n\n"
      text << "- [Complete documentation as one file](#{public_url("llms-full.txt")})\n"
      sections.each do |heading, paths|
        existing = paths.select { |path| available[path] }
        next if existing.empty?

        text << "\n## #{heading}\n\n"
        existing.each do |path|
          text << "- [#{discovery_label(path)}](#{public_url(path)})\n"
        end
      end
      text << "\n## Optional\n\n"
      text << "- [Complete API index](#{public_url("docs/api.md")})\n" if available["docs/api.md"]
      text << "- [Version catalog](#{URI.join(SITE_URL, "versions.json")})\n"
      text << "- [GitHub source](https://github.com/mattyr/little_ghost)\n"
      text
    end

    def llms_full_text
      paths = ["docs/index.md"]
      paths.concat(available_guides.map { |guide| "docs/#{Pathname(guide.fetch(:output)).sub_ext(".md")}" })
      paths << "docs/api.md"
      api_paths = api_objects.map { |object| "docs/#{Pathname(object.path).sub_ext(".md")}" }
      essential = ESSENTIAL_APIS.map { |path| "docs/#{path}.md" } & api_paths
      paths.concat(essential)
      paths.concat((api_paths - essential).sort)
      paths.select! { |path| site_root.join(path).file? }

      text = +"# LittleGhost complete documentation\n\n"
      text << "Version: #{(id == EDGE_ID) ? "Edge" : id}\n\n"
      paths.uniq.each do |path|
        text << "\n---\n\nSource: #{public_url(path)}\n\n"
        text << site_root.join(path).read.rstrip << "\n"
      end
      text
    end

    def discovery_label(path)
      guide = available_guides.find { |entry| "docs/#{Pathname(entry.fetch(:output)).sub_ext(".md")}" == path }
      return guide.fetch(:title) if guide
      return "Documentation home" if path == "docs/index.md"
      return "Complete API index" if path == "docs/api.md"

      path.delete_prefix("docs/").delete_suffix(".md").gsub("/", "::")
    end

    def document_header(title, html_path)
      "# #{title}\n\nDocumentation version: #{(id == EDGE_ID) ? "Edge" : "v#{id}"}\n\nCanonical HTML: #{public_url(html_path)}\n\n"
    end

    def source_document_markdown(markdown, title:, html_path:, output_path:, context:)
      body = rewrite_source_markdown(markdown, output_path:, context:)
      body = body.sub(/\A#\s+[^\n]+\n+/, "")
      document_header(title, html_path) + body
    end

    def render_comment(comment, context:, output_path:)
      return "" if comment.nil? || comment.to_s.strip.empty?

      markdown = RDoc::Markup::ToMarkdown.new.convert(comment.text)
      markdown = markdown.gsub(%r{<code>(.*?)</code>}m) { "`#{Regexp.last_match(1)}`" }
      rewrite_rdoc_links(markdown, context:, output_path:)
    end

    def rewrite_source_markdown(markdown, output_path:, context:)
      rewritten = markdown.gsub(%r{\((docs/guides/([^)/]+)\.md)(#[^)]+)?\)}) do
        source = URI::RFC2396_PARSER.unescape(Regexp.last_match(1))
        rewrite_guide_link(source, Regexp.last_match(3), output_path, Regexp.last_match(0))
      end
      rewritten = rewritten.gsub(%r{\(([^/:)#]+\.md)(#[^)]+)?\)}) do
        source = "docs/guides/#{URI::RFC2396_PARSER.unescape(Regexp.last_match(1))}"
        rewrite_guide_link(source, Regexp.last_match(2), output_path, Regexp.last_match(0))
      end
      rewrite_rdoc_links(rewritten, context:, output_path:)
    end

    def rewrite_guide_link(source, fragment, output_path, original)
      guide = guide_for_source(source)
      return original unless guide

      target = Pathname("docs").join(Pathname(guide.fetch(:output)).sub_ext(".md"))
      relative = target.relative_path_from(output_path.dirname)
      "(#{relative}#{fragment})"
    end

    def rewrite_rdoc_links(markdown, context:, output_path:)
      rewritten = markdown.gsub(/\[([^\]]+)\]\(rdoc-ref:([^)]+)\)/) do
        markdown_link(Regexp.last_match(1), Regexp.last_match(2), context:, output_path:)
      end
      rewritten.gsub(/\{([^}]+)\}\[rdoc-ref:([^\]]+)\]/) do
        markdown_link(Regexp.last_match(1), Regexp.last_match(2), context:, output_path:)
      end
    end

    def markdown_link(label, reference, context:, output_path:)
      target = markdown_target(reference, context:)
      raise Error, "Could not resolve Markdown documentation reference #{reference.inspect}" unless target

      relative = target.relative_path_from(output_path.dirname)
      "[#{label}](#{relative})"
    end

    def markdown_target(reference, context:)
      path, fragment = reference.split("#", 2)
      if path.start_with?("docs/guides/")
        guide = guide_for_source(URI::RFC2396_PARSER.unescape(path))
        return nil unless guide

        target = Pathname("docs").join(Pathname(guide.fetch(:output)).sub_ext(".md"))
        return fragment ? Pathname("#{target}##{fragment}") : target
      end

      resolved = RDoc::CrossReference.new(context || store.find_class_or_module("LittleGhost")).resolve(reference)
      return nil unless resolved.respond_to?(:path)

      resolved_path, resolved_fragment = resolved.path.split("#", 2)
      target = API_ROOT.join(Pathname(resolved_path).sub_ext(".md"))
      anchor = resolved_fragment || fragment
      anchor ? Pathname("#{target}##{anchor}") : target
    rescue RDoc::Error
      nil
    end

    def method_signature(method)
      sequence = method.call_seq.to_s.strip
      return sequence unless sequence.empty?

      "#{method.singleton ? "." : "#"}#{method.name}#{method.params}"
    end

    def api_objects
      @api_objects ||= store.all_classes_and_modules.select do |object|
        object.full_name == "LittleGhost" || object.full_name.start_with?("LittleGhost::")
      end.select { |object| visible?(object) }.sort_by(&:full_name)
    end

    def visible?(object)
      (!object.respond_to?(:display?) || object.display?) &&
        (!object.respond_to?(:document_self) || object.document_self) &&
        (!object.respond_to?(:visibility) || object.visibility == :public)
    end

    def summary_for(object)
      summary = plain_text(render_comment(object.comment, context: object, output_path: Pathname("docs/api.md")))
      sentence = summary.split(/(?<=[.!?])\s+/, 2).first.to_s
      return sentence unless sentence.empty?

      kind = object.is_a?(RDoc::NormalModule) ? "module" : "class"
      "Public #{kind}."
    end

    def rdoc_file(name)
      store.all_files.find { |file| file.full_name == name }
    end

    def available_guides
      @available_guides ||= begin
        configured = GUIDES.select { |guide| source_root.join(guide.fetch(:source)).file? }
        configured_sources = configured.to_h { |guide| [guide.fetch(:source), true] }
        discovered = source_root.glob("docs/guides/*.md").sort.filter_map do |source|
          relative = source.relative_path_from(source_root).to_s
          next if configured_sources[relative]

          basename = source.basename(".md").to_s
          slug = basename.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
          {
            source: relative,
            output: "#{slug}.html",
            title: basename.tr("_", " "),
            section: "Learn"
          }
        end
        configured + discovered
      end
    end

    def guide_for_source(path)
      available_guides.find { |guide| guide.fetch(:source) == path }
    end

    def anchor_from(path)
      path.to_s.split("#", 2).last
    end

    def public_url(path)
      if path.to_s.empty?
        relative_base = base_path.cleanpath.to_s
        relative_base = "" if relative_base == "."
        relative_base = "#{relative_base}/" unless relative_base.empty?
        return URI.join(SITE_URL, relative_base).to_s
      end

      relative = base_path.join(path.to_s).cleanpath.to_s
      relative = "" if relative == "."
      relative = "#{relative}/" if path.to_s.end_with?("/") && !relative.empty?
      URI.join(SITE_URL, relative).to_s
    end

    def markdown_pages
      site_root.glob("**/*.md").sort
    end

    def plain_text(html)
      text = html.to_s.gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1").gsub(/<[^>]+>/, " ").gsub(/[`*_]/, "")
      CGI.unescapeHTML(text).split.join(" ")
    end

    def normalize(markdown)
      markdown.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").rstrip << "\n"
    end

    def write(relative_path, contents)
      path = site_root.join(relative_path)
      FileUtils.mkdir_p(path.dirname)
      path.write(normalize(rewrite_public_urls(contents)))
    end

    def rewrite_public_urls(contents)
      return contents if base_path.to_s.empty? || base_path.to_s == "."

      deployed_url = URI.join(SITE_URL, "#{base_path}/").to_s
      contents.gsub(UNVERSIONED_SITE_URL_PATTERN, deployed_url)
    end
  end
end
