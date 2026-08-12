# frozen_string_literal: true

require "test_helper"
require "little_ghost/model_catalog_snapshot"

class ModelCatalogSnapshotTest < Minitest::Test
  def test_generation_is_sorted_and_normalized
    document = LittleGhost::ModelCatalogSnapshot::NAMESPACES.to_h do |namespace, _provider|
      [namespace, {"models" => {}}]
    end
    document["openrouter"]["models"] = {
      "z-model" => {"limit" => {"context" => 100}, "cost" => {"input" => 1.0}},
      "a-model" => {"limit" => {"output" => 20}, "tool_call" => true}
    }

    first = LittleGhost::ModelCatalogSnapshot.generate(document)
    second = LittleGhost::ModelCatalogSnapshot.generate(document)
    parsed = JSON.parse(first)

    assert_equal first, second
    assert_operator first.index("openrouter:a-model"), :<, first.index("openrouter:z-model")
    assert_equal 20, parsed.dig("openrouter:a-model", "max_output_tokens")
    assert_equal ["tools"], parsed.dig("openrouter:a-model", "supported_parameters")
    assert_equal 1.0, parsed.dig("openrouter:z-model", "pricing", "input")
  end

  def test_packaged_snapshot_is_deterministically_ordered_and_normalized
    packaged = JSON.parse(File.read(LittleGhost::ModelCatalog::SNAPSHOT_PATH))

    providers = packaged.keys.map { |target| target.split(":", 2).first }
    expected_provider_order = LittleGhost::ModelCatalogSnapshot::NAMESPACES.sort.map(&:last)
    assert_equal expected_provider_order, providers.uniq
    providers.uniq.each do |provider|
      targets = packaged.keys.select { |target| target.start_with?("#{provider}:") }
      assert_equal targets.sort, targets
    end
    assert packaged.keys.any? { |target| target.start_with?("bedrock:") }
    assert packaged.keys.any? { |target| target.start_with?("vertex_ai:") }
    assert packaged.values.all? { |attributes| attributes.fetch("provenance").values.all? { |source| source == "bundled:models.dev" } }
  end
end
