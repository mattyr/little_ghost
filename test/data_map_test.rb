# frozen_string_literal: true

require "test_helper"

class DataMapTest < Minitest::Test
  def test_normalizes_nested_data_and_accepts_symbol_or_string_access
    data = LittleGhost::DataMap.new(plan: {status: "active", items: [{id: "inspect"}]})

    assert_equal "active", data.dig("plan", :status)
    assert_equal "inspect", data.dig(:plan, "items", 0, :id)
    assert_equal ["plan"], data.keys
    assert_equal({"plan" => {"status" => "active", "items" => [{"id" => "inspect"}]}}, data.to_h)
  end

  def test_normalizes_mutation_and_merging
    data = LittleGhost::DataMap.new
    data[:plan] = {status: "active"}
    data.dig("plan")[:status] = "completed"
    merged = data.merge("attempt" => 2)
    duplicate = data.dup

    assert_equal "completed", data.dig(:plan, :status)
    assert_equal 2, merged[:attempt]
    refute data.key?(:attempt)
    assert_equal "completed", duplicate.dig(:plan, :status)
  end

  def test_rejects_ambiguous_or_non_json_data
    ambiguous = {status: "one"}
    ambiguous["status"] = "two"

    assert_raises(ArgumentError) { LittleGhost::DataMap.new(ambiguous) }
    assert_raises(ArgumentError) { LittleGhost::DataMap.new(status: Object.new) }
    assert_raises(ArgumentError) { LittleGhost::DataMap.new(Object.new => "value") }
  end

  def test_rejects_cyclic_data_without_limiting_valid_nesting
    cyclic = {}
    cyclic["self"] = cyclic
    nested = {}
    cursor = nested
    2_000.times do
      child = {}
      cursor["child"] = child
      cursor = child
    end

    assert_raises(ArgumentError) { LittleGhost::DataMap.new(cyclic) }
    assert_instance_of LittleGhost::DataMap, LittleGhost::DataMap.new(nested)
  end
end
