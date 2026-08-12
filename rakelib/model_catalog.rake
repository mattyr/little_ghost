# frozen_string_literal: true

require "uri"
require_relative "../lib/little_ghost"

namespace :models do
  desc "Regenerate lib/little_ghost/data/model_catalog.json from models.dev"
  task :snapshot do
    uri = URI("https://models.dev/api.json")
    response = LittleGhost::Support::HTTPClient.new(max_response_bytes: 25 * 1024 * 1024).request(uri:)
    document = JSON.parse(response)
    path = File.expand_path("../lib/little_ghost/data/model_catalog.json", __dir__)
    File.write(path, LittleGhost::Models::CatalogSnapshot.generate(document))
    puts "Wrote #{path}"
  end
end
