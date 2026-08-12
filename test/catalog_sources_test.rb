# frozen_string_literal: true

require "test_helper"

class CatalogSourcesTest < Minitest::Test
  Response = Struct.new(:code, :chunks) do
    def is_a?(type) = type == Net::HTTPSuccess
    def read_body = chunks.each { |chunk| yield chunk }
  end

  class FakeHTTP
    def initialize(response) = @response = response
    def request(_request) = yield @response
  end

  def test_catalog_reader_rejects_oversized_success_body
    response = Response.new("200", ["a" * 6, "b" * 6])
    starter = ->(*_arguments, **_options, &block) { block.call(FakeHTTP.new(response)) }
    Net::HTTP.stub(:start, starter) do
      error = assert_raises(LittleGhost::ProviderError) do
        LittleGhost::CatalogSources.get(URI("https://catalog.example/models"), label: "catalog", max_bytes: 10)
      end

      assert_includes error.message, "exceeded"
    end
  end
end
