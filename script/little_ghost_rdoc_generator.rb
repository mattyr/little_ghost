# frozen_string_literal: true

require "pathname"
require "rdoc/rdoc"

class RDoc::Generator::LittleGhost < RDoc::Generator::Aliki
  DESCRIPTION = "Aliki with LittleGhost navigation"
  ALIKI_TEMPLATE = Pathname.new(
    File.join(File.dirname(RDoc::Generator::Aliki.instance_method(:initialize).source_location.first), "template", "aliki")
  ).freeze
  HEADER_TEMPLATE = Pathname.new(File.expand_path("rdoc/_header.rhtml", __dir__)).freeze

  RDoc::RDoc.add_generator self

  def initialize(store, options)
    options.template_dir ||= ALIKI_TEMPLATE.to_s
    super
  end

  def render(file_name)
    return super unless file_name == "_header.rhtml"

    template = template_for(HEADER_TEMPLATE, false, RDoc::ERBPartial)
    template.filename = HEADER_TEMPLATE.to_s
    template.result(@context)
  end
end
