# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "../lib/little_ghost/model_catalog_snapshot"

namespace :models do
  desc "Regenerate lib/little_ghost/model_catalog.json from models.dev"
  task :snapshot do
    uri = URI("https://models.dev/api.json")
    response = Net::HTTP.get_response(uri)
    abort "models.dev returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    document = JSON.parse(response.body)
    path = File.expand_path("../lib/little_ghost/model_catalog.json", __dir__)
    File.write(path, LittleGhost::ModelCatalogSnapshot.generate(document))
    puts "Wrote #{path}"
  end
end
