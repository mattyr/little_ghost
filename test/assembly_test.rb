# frozen_string_literal: true

require "test_helper"

class AssemblyTest < Minitest::Test
  class DevelopmentWorkflow < LittleGhost::Workflow
    private

    def perform = raise("not used")
  end

  class ActiveAssembly < LittleGhost::Assembly
    def activate(child, &block)
      with_active_assembly(child, &block)
    end
  end

  def test_assemblies_derive_identity_kind_and_description
    DevelopmentWorkflow.description "Coordinates development"

    assert_equal "development", DevelopmentWorkflow.assembly_id
    assert_equal :workflow, DevelopmentWorkflow.assembly_kind
    assert_equal "Coordinates development", DevelopmentWorkflow.description
    assert_equal :agent, Class.new(LittleGhost::Agent).assembly_kind
    assert_equal "agent", Class.new(LittleGhost::Agent).assembly_id

    agent_class = Class.new(LittleGhost::Agent)
    agent_class.agent_id "support"
    assert_equal "support", agent_class.assembly_id
    agent_class.assembly_id "customer_support"
    assert_equal "customer_support", agent_class.agent_id
  end

  def test_standalone_call_builds_a_run_for_the_assembly
    calls = []
    completed_run = Object.new
    completed_run.define_singleton_method(:call) { self }
    runtime = Object.new
    runtime.define_singleton_method(:build_run) do |payload, **options|
      calls << [payload, options]
      completed_run
    end
    assembly_class = Class.new(LittleGhost::Assembly)

    result = assembly_class.new(runtime:).ask("hello", context: {request_id: "request-1"})

    assert_same completed_run, result
    assert_equal({message: "hello", context: {request_id: "request-1"}}, calls.first.fetch(0))
    assert_equal assembly_class, calls.first.fetch(1).fetch(:entrypoint_class)
  end

  def test_standalone_call_transfers_the_cancellation_token_to_the_run
    options = nil
    runtime = Object.new
    runtime.define_singleton_method(:build_run) do |_payload, **values|
      options = values
      Object.new.tap { |run| run.define_singleton_method(:call) { self } }
    end
    token = LittleGhost::Support::CancellationToken.new

    Class.new(LittleGhost::Assembly).new(runtime:).ask("hello", cancellation_token: token)

    assert_same token, options.fetch(:cancellation_token)
  end

  def test_interjections_route_to_the_single_active_child
    responses = []
    child = Object.new
    child.define_singleton_method(:interject) do |message, **options|
      responses << [message, options]
      :response
    end
    assembly = ActiveAssembly.new(runtime: Object.new)

    result = assembly.activate(child) do
      assembly.interject("status", metadata: {source: "test"})
    end

    assert_equal :response, result
    assert_equal [["status", {metadata: {source: "test"}}]], responses
    assert_raises(LittleGhost::AgentInterjectionError) { assembly.interject("late") }
  end

  def test_agents_can_declare_any_assembly_as_a_tool
    graph_class = Class.new(LittleGhost::Graph) do
      assembly_id "support_flow"
      description "Routes a support request"
    end
    agent_class = Class.new(LittleGhost::Agent) do
      assembly_as_tool graph_class
    end

    declaration = agent_class.assembly_tool_declarations.fetch(0)

    assert_same graph_class, declaration.fetch(:assembly)
    assert_equal "support_flow", declaration.fetch(:name)
    assert_equal "Routes a support request", declaration.fetch(:description)
    assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::Agent) { assembly_as_tool graph_class, model: "main" }
    end
  end

  def test_composite_assembly_tools_build_a_fresh_instance_per_call
    assembly_class = Class.new(LittleGhost::Assembly) do
      def stream(input, **_options)
        raise "reused" if @used

        @used = true
        result = LittleGhost::RunResult.new(
          message: LittleGhost::Message.new(role: :assistant, content: input),
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new,
          messages: [],
          state: {}
        )
        [LittleGhost::StreamEvent.build(:invocation_stop, result:)].each
      end
    end
    runtime = Object.new
    run = Struct.new(:runtime, :operation_id).new(runtime, "run-1")
    runtime.define_singleton_method(:build_assembly) do |klass, run:|
      klass.new(run:, runtime: self)
    end
    assembly = assembly_class.new(run:, runtime:)
    tool = assembly.as_tool

    first = tool.execute({"input" => "one"})
    second = tool.execute({"input" => "two"})

    assert_equal "one", first.content
    assert_equal "two", second.content
  ensure
    tool&.close
  end
end
