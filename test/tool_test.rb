# frozen_string_literal: true

require "test_helper"
require "little_ghost/tool"

class ToolTest < Minitest::Test
  class Weather < LittleGhost::Tool
    tool_name "weather"
    description "Looks up weather"
    input_schema(
      type: "object",
      properties: {
        city: {type: "string"},
        units: {type: "string", enum: %w[celsius fahrenheit]},
        days: {type: "array", items: {type: "integer", minimum: 1, maximum: 10}}
      },
      required: ["city"],
      additionalProperties: false
    )

    def call(input, context:)
      {city: input[:city], request_id: context[:request_id]}
    end
  end

  def test_class_dsl_and_specification
    assert_equal "ToolTest::Weather", Weather.name
    assert_equal "weather", Weather.tool_name
    assert_equal "Looks up weather", Weather.description
    assert_equal "object", Weather.input_schema["type"]
    assert Weather.input_schema.frozen?
    assert_equal "weather", Weather.specification[:name]
  end

  def test_execute_validates_and_sanitizes_json_results
    result = Weather.new.execute(
      {city: "London", units: "celsius", days: [1, 2]},
      context: {request_id: "request-1"}
    )

    assert result.success?
    assert_equal({"city" => "London", "request_id" => "request-1"}, JSON.parse(result.content))
  end

  def test_execute_reports_all_supported_schema_errors
    result = Weather.new.execute(
      {units: "kelvin", days: ["tomorrow"], surprise: true}
    )

    assert result.error?
    assert_includes result.content, "$.city is required"
    assert_includes result.content, "$.units must be one of"
    assert_includes result.content, "$.days[0] must be integer"
    assert_includes result.content, "$.surprise is not allowed"
  end

  def test_execute_rejects_an_incorrect_root_type
    result = Weather.new.execute("London")

    assert_equal :error, result.status
    assert_includes result.content, "$ must be object"
  end

  def test_execute_enforces_numeric_bounds
    result = Weather.new.execute({city: "London", days: [0, 11]})

    assert_includes result.content, "$.days[0] must be at least 1"
    assert_includes result.content, "$.days[1] must be at most 10"
  end

  def test_execute_sanitizes_tool_exceptions
    tool = LittleGhost::Tool.define(name: "broken", description: "Fails") do |_input|
      raise "secret credentials"
    end

    result = tool.new.execute({})

    assert_equal "Tool failed (RuntimeError)", result.content
    refute_includes result.content, "secret credentials"
    assert_instance_of RuntimeError, result.error
    assert_equal "secret credentials", result.error.message
  end

  def test_execute_preserves_intentional_tool_errors
    tool = LittleGhost::Tool.define(name: "denied", description: "Fails safely") do |_input|
      raise LittleGhost::ToolError, "permission denied"
    end

    result = tool.new.execute({})

    assert_equal :error, result.status
    assert_equal "permission denied", result.content
    assert_instance_of LittleGhost::ToolError, result.error
  end

  def test_execute_propagates_cleanup_errors
    error = LittleGhost::CleanupError.new("work is still running")
    tool = LittleGhost::Tool.define(name: "unclean", description: "Fails to stop") do |_input|
      raise error
    end

    raised = assert_raises(LittleGhost::CleanupError) { tool.new.execute({}) }

    assert_same error, raised
  end

  def test_define_supports_context_and_freezes_scalar_results
    tool = LittleGhost::Tool.define(name: "echo", description: "Echoes", input_schema: {type: "string"}) do |input, context:|
      "#{context[:prefix]}#{input}"
    end

    result = tool.new.execute("hello", context: {prefix: "> "})

    assert_equal "> hello", result.content
    assert result.content.frozen?
  end

  def test_tool_names_default_from_the_ruby_class_name
    klass = Class.new(LittleGhost::Tool)
    stub_const = Module.new
    stub_const.const_set(:ReadFile, klass)

    assert_match(/::ReadFile\z/, klass.name)
    assert_equal "read_file", klass.tool_name
  end

  def test_input_schema_must_be_a_hash
    assert_raises(ArgumentError) do
      Class.new(LittleGhost::Tool).input_schema([])
    end
  end
end
