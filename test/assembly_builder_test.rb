# frozen_string_literal: true

require "test_helper"

class AssemblyBuilderTest < Minitest::Test
  class FirstAgent < LittleGhost::Agent
    description "First"
  end

  class SecondAgent < LittleGhost::Agent
    description "Second"
  end

  def test_agent_builder_snapshots_declarative_configuration
    id = +"dynamic_helper"
    prompt = +"Help clearly"
    builder = LittleGhost::AgentBuilder.new(id:)
    builder.model(:main).system_prompt(prompt).limits(max_turns: 3)

    first = builder.definition
    id.replace("mutated")
    prompt.replace("Mutated externally")
    builder.system_prompt("Changed later")

    assert_equal :agent, first.kind
    assert_equal "dynamic_helper", first.assembly_id
    assert_equal :main, first.implementation.model
    assert_equal "Help clearly", first.implementation.system_prompt
    assert_equal 3, first.implementation.limits.fetch(:max_turns)
    assert first.implementation.frozen?
  end

  def test_class_snapshots_preserve_custom_class_configuration
    workflow = Class.new(LittleGhost::Workflow) do
      class << self
        attr_accessor :target
      end
      self.target = {name: +"configured"}

      private

      def perform = invoke(self.class.target)
    end

    implementation = workflow.definition.implementation
    workflow.target.fetch(:name).replace("mutated")

    assert_equal({name: "configured"}, implementation.target)
    assert_nil implementation.name
    assert implementation.frozen?
    assert_raises(FrozenError) { implementation.target.fetch(:name).replace("changed") }
    assert_raises(FrozenError) { implementation.target = {name: "changed"} }
    assert_equal({name: "mutated"}, workflow.target)
  end

  def test_graph_builder_is_mutable_and_produces_isolated_snapshots
    builder = LittleGhost::GraphBuilder.new(id: "dynamic_graph")
    builder.node(:first, FirstAgent).start(:first).finish(:first)
    first = builder.definition
    builder.description("A later description")
    second = builder.definition

    assert_equal "", first.description
    assert_equal "A later description", second.description
    assert_equal :graph, first.kind
    assert_includes builder.to_mermaid, "n_first[first]"
  end

  def test_class_to_builder_inherits_without_mutating_class
    graph_class = Class.new(LittleGhost::Graph) do
      assembly_id "base_graph"
      node :first, FirstAgent
      start :first
      finish :first
    end

    builder = graph_class.to_builder
    builder.description("Dynamic variant")

    assert_equal "", graph_class.description
    assert_equal "Dynamic variant", builder.definition.description
    assert_equal "base_graph", builder.assembly_id
  end

  def test_class_definition_is_an_immutable_snapshot
    agent_class = Class.new(LittleGhost::Agent) do
      agent_id "snapshot_agent"
      model :first
    end
    snapshot = agent_class.definition

    agent_class.model :second

    assert_equal :first, snapshot.implementation.model
    assert_equal :second, agent_class.model
    assert snapshot.implementation.frozen?
    named = FirstAgent.definition
    assert_equal FirstAgent.name, named.implementation.name
    assert_raises(FrozenError) { snapshot.implementation.model :third }
    assert_raises(FrozenError) { snapshot.implementation.assembly_id "changed" }
  end

  def test_graph_definition_recursively_snapshots_child_assemblies
    child = Class.new(LittleGhost::Agent) do
      agent_id "child"
      model :first
    end
    graph = LittleGhost::GraphBuilder.new
      .node(:child, child)
      .start(:child)
      .finish(:child)
      .definition

    child.model :second
    snapshotted_child = graph.implementation.graph_nodes_value.fetch(:child).assembly

    assert_instance_of LittleGhost::AssemblyDefinition, snapshotted_child
    assert_equal :first, snapshotted_child.implementation.model
    assert_raises(FrozenError) do
      graph.implementation.graph_nodes_value[:injected] = :invalid
    end
  end

  def test_snapshots_own_nested_data_and_policy_containers
    holder = Data.define(:nested)
    nested = +"value"
    retry_on = [RuntimeError]
    graph = Class.new(LittleGhost::Graph) do
      class << self
        attr_accessor :custom
      end
      self.custom = holder.new(nested:)
      node(:child, FirstAgent, retries: 1, retry_on:)
      start :child
      finish :child
    end

    snapshot = graph.definition.implementation
    nested.replace("source changed")
    retry_on.clear

    assert_equal "value", snapshot.custom.nested
    assert_equal [RuntimeError], snapshot.graph_nodes_value.fetch(:child).policies.fetch(:retry_on)
    assert_raises(FrozenError) { snapshot.custom.nested.replace("snapshot changed") }
  end

  def test_agent_definition_recursively_snapshots_static_subagents
    child_class = Class.new(LittleGhost::Agent) { model :before_snapshot }
    parent_class = Class.new(LittleGhost::Agent) { subagent child_class }
    snapshot = parent_class.definition
    child_class.model :changed_after_snapshot
    child = snapshot.implementation.subagent_declarations.first.fetch(:agent)

    assert_instance_of LittleGhost::AssemblyDefinition, child
    assert_equal :before_snapshot, child.implementation.model
  end

  def test_rejects_recursive_assembly_definitions
    graph = Class.new(LittleGhost::Graph)
    graph.node(:self, graph)
    graph.start(:self)
    graph.finish(:self)

    error = assert_raises(LittleGhost::ConfigurationError) { graph.definition }

    assert_includes error.message, "recursively"
  end

  def test_rejects_cyclic_builder_configuration
    cyclic = {}
    cyclic[:self] = cyclic
    builder = LittleGhost::AgentBuilder.new.limits(cyclic)

    error = assert_raises(ArgumentError) { builder.definition }

    assert_includes error.message, "cyclic"
  end

  def test_swarm_builder_rejects_non_agent_members
    builder = LittleGhost::SwarmBuilder.new
    builder.member(LittleGhost::Workflow).member(FirstAgent).start(FirstAgent)

    error = assert_raises(LittleGhost::ConfigurationError) { builder.validate! }

    assert_includes error.message, "Agent definitions"
  end

  def test_runtime_builds_dynamic_agent_definition
    builder = LittleGhost::AgentBuilder.new(id: "dynamic")
    builder.model(:main).system_prompt("Dynamic")
    run = Struct.new(:workspace, :sandbox, :runtime, :invocation, :session, :cancellation_token).new(
      nil, nil, nil, nil, nil, LittleGhost::Support::CancellationToken.new
    )
    runtime = Object.new
    built = nil
    runtime.define_singleton_method(:build_agent) do |definition, run:, **|
      built = [definition, run]
      :agent
    end

    assert_equal :agent, runtime.build_agent(builder.definition, run:)
    assert_equal :agent, built.first.kind
  end
end
