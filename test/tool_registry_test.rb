# frozen_string_literal: true

require "test_helper"
require "little_ghost/tool"
require "little_ghost/tool_registry"

class ToolRegistryTest < Minitest::Test
  def build_tool(name)
    LittleGhost::Tool.define(name: name, description: "A tool") { "done" }
  end

  def test_registers_classes_and_instances_in_order
    first = build_tool("first")
    second = build_tool("second")
    registry = LittleGhost::ToolRegistry.new([first, second.new])

    assert_equal %w[first second], registry.names
    assert_instance_of first, registry.fetch(:first)
    assert_equal %w[first second], registry.specifications.map { |specification| specification[:name] }
  end

  def test_constructs_classes_with_the_tool_context
    run = Object.new
    tool = Class.new(LittleGhost::Tool) do
      tool_name "dynamic"
      description "Dynamic"
    end
    tool_context = LittleGhost::ToolContext.new(run:)
    registry = LittleGhost::ToolRegistry.new([tool], tool_context:)

    assert_same run, registry.fetch("dynamic").run
  end

  def test_resolves_provider_classes_with_their_context
    tool = build_tool("provided")
    provider = Class.new(LittleGhost::ToolProvider) do
      def tools = [self.class.tool]

      class << self
        attr_accessor :tool
      end
    end
    provider.tool = tool
    tool_context = LittleGhost::ToolContext.new(run: Object.new)
    registry = LittleGhost::ToolRegistry.new([provider], tool_context:)

    assert_equal ["provided"], registry.names
    assert_same tool_context.run, registry.fetch("provided").run
  end

  def test_closes_partial_provider_results_when_a_later_constructor_fails
    closable = Class.new(LittleGhost::Tool) do
      tool_name "closable"
      description "Closable"

      class << self
        attr_accessor :closes
      end

      def close = self.class.closes = self.class.closes.to_i + 1
    end
    failing = Class.new(LittleGhost::Tool) do
      tool_name "failing"
      description "Failing"

      def initialize(...) = raise "failed"
    end

    assert_raises(RuntimeError) do
      provider = Class.new(LittleGhost::ToolProvider) do
        def tools = [self.class.closable, self.class.failing]

        class << self
          attr_accessor :closable, :failing
        end
      end
      provider.closable = closable
      provider.failing = failing
      LittleGhost::ToolRegistry.new([provider])
    end

    assert_equal 1, closable.closes
  end

  def test_does_not_treat_arbitrary_callable_objects_as_resolvers
    callable = Object.new
    callable.define_singleton_method(:call) { [] }

    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([callable])
    end
  end

  def test_rejects_name_collisions
    registry = LittleGhost::ToolRegistry.new([build_tool("same")])

    error = assert_raises(LittleGhost::ConfigurationError) do
      registry.register(build_tool("same"))
    end
    assert_includes error.message, "collision"
  end

  def test_rejects_names_over_64_characters
    error = assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([build_tool("a" * 65)])
    end

    assert_includes error.message, "64"
  end

  def test_rejects_unsafe_names_and_non_tools
    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([build_tool("bad name")])
    end
    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([Object.new])
    end
  end

  def test_rejects_a_missing_description
    tool = Class.new(LittleGhost::Tool) do
      tool_name "undescribed"
    end

    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([tool])
    end
  end

  def test_unknown_tools_raise_a_sanitized_error
    error = assert_raises(LittleGhost::ToolError) do
      LittleGhost::ToolRegistry.new.fetch("missing")
    end

    assert_equal "Unknown tool: missing", error.message
  end

  def test_rejects_registration_after_close
    registry = LittleGhost::ToolRegistry.new
    registry.close

    assert_raises(LittleGhost::Error) { registry.register(build_tool("late")) }
  end

  def test_initialization_closes_unprocessed_tools_even_when_an_earlier_close_fails
    raising = Class.new(LittleGhost::Tool) do
      tool_name "raising_close"
      description "Raises while closing"

      def close = raise "close failed"
    end.new
    later = Class.new(LittleGhost::Tool) do
      tool_name "later"
      description "Later tool"
      attr_reader :closed

      def close = @closed = true
    end.new

    assert_raises(LittleGhost::ConfigurationError) do
      LittleGhost::ToolRegistry.new([raising, Object.new, later])
    end

    assert later.closed
  end
end
