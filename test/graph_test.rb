# frozen_string_literal: true

require "test_helper"

class GraphTest < Minitest::Test
  class FakeAssembly
    attr_reader :calls

    def initialize(result, failure_usage: LittleGhost::Usage.new)
      @result = result
      @failure_usage = failure_usage
      @calls = []
    end

    def stream(input, **options)
      calls << [input, options]
      events = @result.is_a?(Exception) ? [
        LittleGhost::StreamEvent.build(:invocation_error, error: @result, usage: @failure_usage, metadata: {})
      ] : [
        LittleGhost::StreamEvent.build(:text_delta, text: @result.text),
        LittleGhost::StreamEvent.build(:invocation_stop, result: @result)
      ]
      Enumerator.new do |stream|
        events.each { |event| stream << event }
        raise @result if @result.is_a?(Exception)
      end
    end

    def interject(...) = nil
    def close = @closed = true
    def closed? = @closed == true
  end

  class Runtime
    attr_reader :built

    def initialize(assemblies)
      @assemblies = assemblies.transform_values(&:dup)
      @built = []
    end

    def build_assembly(declaration, run:)
      built << [declaration, run]
      @assemblies.fetch(declaration).shift
    end

    def template_locals(run:, agent:) = {run:, agent:}
  end

  Run = Struct.new(:runtime)

  def test_runs_one_path_and_only_streams_the_finish_node
    graph_class = Class.new(LittleGhost::Graph) do
      node :classify, :classifier
      node :refund, :refund_agent
      node :answer, :answer_agent
      start :classify
      edge :classify, :refund, if: ->(state) { state.result(:classify).output == "refund" }
      edge :classify, :answer
      edge :refund, :answer
      finish :answer
    end
    classifier = FakeAssembly.new(result("refund", input_tokens: 2))
    refund = FakeAssembly.new(result("approved", input_tokens: 3))
    answer = FakeAssembly.new(result("done", input_tokens: 5))
    runtime = Runtime.new(classifier: [classifier], refund_agent: [refund], answer_agent: [answer])
    graph = graph_class.new(run: Run.new(runtime), runtime:)

    events = graph.stream("request").to_a

    assert_equal %i[
      assembly_step_start assembly_step_stop assembly_transition
      assembly_step_start assembly_step_stop assembly_transition
      assembly_step_start assembly_step_stop text_delta invocation_stop
    ], events.map(&:type)
    assert_equal 10, events.find { |event| event.type == :invocation_stop }.data.fetch(:result).usage.input_tokens
    assert_equal "request", classifier.calls.first.first.text
    assert_empty classifier.calls.first.last.fetch(:history)
    assert_empty classifier.calls.first.last.fetch(:context)
    assert_includes refund.calls.first.first.text, "classify output:\nrefund"
    assert_includes answer.calls.first.first.text, "refund output:\napproved"
    refute events.any? { |event| event.type == :text_delta && event.data[:text] == "refund" }
    refute events.any? { |event| event.type == :text_delta && event.data[:text] == "approved" }
    assert classifier.closed?
    assert refund.closed?
    assert answer.closed?
  end

  def test_input_mapper_replaces_the_default_downstream_input
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last
      start :first
      edge :first, :last, input: ->(state) { "mapped: #{state.previous_result.text}" }
      finish :last
    end
    first = FakeAssembly.new(result("evidence"))
    last = FakeAssembly.new(result("done"))
    runtime = Runtime.new(first: [first], last: [last])

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "mapped: evidence", last.calls.first.first
  end

  def test_node_can_explicitly_inherit_caller_history_and_context
    graph_class = Class.new(LittleGhost::Graph) do
      node :answer, :answer, history: true, context: true
      start :answer
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(answer: [answer])
    history = [LittleGhost::Message.new(role: :assistant, content: "prior")]

    graph_class.new(run: Run.new(runtime), runtime:).stream(
      "request",
      history:,
      context: {"request_id" => "one"}
    ).to_a

    assert_equal ["prior"], answer.calls.first.last.fetch(:history).map(&:text)
    assert_equal({"request_id" => "one"}, answer.calls.first.last.fetch(:context))
  end

  def test_uses_the_mapper_from_the_selected_same_target_edge
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last
      start :first
      edge :first, :last, input: ->(_state) { "wrong" }, if: ->(_state) { false }
      edge :first, :last, input: ->(_state) { "selected" }, if: ->(_state) { true }
      finish :last
    end
    first = FakeAssembly.new(result("route"))
    last = FakeAssembly.new(result("done"))
    runtime = Runtime.new(first: [first], last: [last])

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "selected", last.calls.first.first
  end

  def test_routing_state_context_is_deeply_immutable
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last
      start :first
      edge :first, :last, if: lambda { |state|
        state.context.fetch("nested") << "changed"
        true
      }
      finish :last
    end
    runtime = Runtime.new(first: [FakeAssembly.new(result("route"))])

    assert_raises(FrozenError) do
      graph_class.new(run: Run.new(runtime), runtime:).stream("request", context: {"nested" => []}).to_a
    end
  end

  def test_rejects_ambiguous_routing
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :second, :second
      node :third, :third
      start :first
      edge :first, :second, if: ->(_state) { true }
      edge :first, :third, if: ->(_state) { true }
      edge :third, :second
      finish :second
    end
    runtime = Runtime.new(first: [FakeAssembly.new(result("route"))])
    graph = graph_class.new(run: Run.new(runtime), runtime:)

    error = assert_raises(LittleGhost::AssemblyRoutingError) { graph.stream("request").to_a }

    assert_includes error.message, "more than one conditional edge"
  end

  def test_bounds_cycles
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :second, :second
      node :finish, :finish
      start :first
      edge :first, :second
      edge :second, :first
      finish :finish
      max_steps 2
    end
    runtime = Runtime.new(
      first: [FakeAssembly.new(result("one"))],
      second: [FakeAssembly.new(result("two"))]
    )

    error = assert_raises(LittleGhost::ConfigurationError) do
      graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    end

    assert_includes error.message, "unreachable"
  end

  def test_validates_finish_edges
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last
      start :first
      edge :first, :last
      edge :last, :first
      finish :last
    end

    error = assert_raises(LittleGhost::ConfigurationError) { graph_class.graph_definition! }

    assert_includes error.message, "cannot have outgoing edges"
  end

  def test_runs_fork_branches_and_joins_their_outputs
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      fork :plan, to: [:research, :verify], max_concurrency: 2
      join [:research, :verify], to: :answer
      finish :answer
    end
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan", input_tokens: 1))],
      research: [FakeAssembly.new(result("facts", input_tokens: 2))],
      verify: [FakeAssembly.new(result("checked", input_tokens: 3))],
      answer: [FakeAssembly.new(result("done", input_tokens: 4))]
    )

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    final = events.find { |event| event.type == :invocation_stop }.data.fetch(:result)
    answer = runtime.built.find { |declaration, _| declaration == :answer }

    assert_includes events.map(&:type), :assembly_fork
    assert_includes events.map(&:type), :assembly_join
    assert_equal %w[plan research verify answer], final.steps.map(&:participant)
    assert_equal 10, final.usage.input_tokens
    refute_nil answer
  end

  def test_max_steps_is_shared_across_parallel_branches
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      fork :plan, to: [:research, :verify], max_concurrency: 2
      join [:research, :verify], to: :answer
      finish :answer
      max_steps 2
    end
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research: [FakeAssembly.new(result("facts"))],
      verify: [FakeAssembly.new(result("checked"))]
    )

    error = assert_raises(LittleGhost::AssemblyLimitError) do
      graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    end

    assert_includes error.message, "max_steps"
    assert_equal 2, runtime.built.length
  end

  def test_routes_a_node_error_to_a_fallback
    error = RuntimeError.new("offline")
    graph_class = Class.new(LittleGhost::Graph) do
      node :research, :research
      node :fallback, :fallback
      node :answer, :answer
      start :research
      error_edge :research, :fallback, on: [RuntimeError], input: ->(state) { "failed: #{state.error.message}" }
      edge :research, :answer
      edge :fallback, :answer
      finish :answer
    end
    research = FakeAssembly.new(error)
    fallback = FakeAssembly.new(result("cached"))
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(research: [research], fallback: [fallback], answer: [answer])

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    final = events.find { |event| event.type == :invocation_stop }.data.fetch(:result)

    assert_equal "failed: offline", fallback.calls.first.first
    assert_equal :failed, final.steps.first.status
    assert_equal %w[research fallback answer], final.steps.map(&:participant)
    assert_equal [final.steps[0].id], final.steps[1].predecessor_ids
    assert_equal [final.steps[1].id], final.steps[2].predecessor_ids
  end

  def test_error_route_without_mapper_uses_a_safe_default_input
    graph_class = Class.new(LittleGhost::Graph) do
      node :research, :research
      node :fallback, :fallback
      start :research
      edge :research, :fallback
      error_edge :research, :fallback, on: [RuntimeError]
      finish :fallback
    end
    fallback = FakeAssembly.new(result("cached"))
    runtime = Runtime.new(
      research: [FakeAssembly.new(RuntimeError.new("secret failure detail"))],
      fallback: [fallback]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_includes fallback.calls.first.first.text, "RuntimeError"
    refute_includes fallback.calls.first.first.text, "secret failure detail"
  end

  def test_fork_branches_follow_edges_to_their_join_sources
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research_start, :research_start
      node :research_done, :research_done
      node :verify_start, :verify_start
      node :verify_done, :verify_done
      node :answer, :answer
      start :plan
      fork :plan, to: [:research_start, :verify_start]
      edge :research_start, :research_done
      edge :verify_start, :verify_done
      join [:research_done, :verify_done], to: :answer
      finish :answer
    end
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research_start: [FakeAssembly.new(result("researching"))],
      research_done: [FakeAssembly.new(result("facts"))],
      verify_start: [FakeAssembly.new(result("verifying"))],
      verify_done: [FakeAssembly.new(result("checked"))],
      answer: [FakeAssembly.new(result("done"))]
    )

    final = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a.last.data.fetch(:result)

    assert_equal 6, final.steps.length
    predecessors = final.trajectory.step(final.steps.last.id).predecessor_ids.map do |id|
      final.trajectory.step(id).participant
    end
    assert_equal %w[research_done verify_done], predecessors.sort
  end

  def test_validates_node_policies_before_execution
    graph = LittleGhost::GraphBuilder.new
      .node(:first, :first, retries: 1)
      .node(:last, :last)
      .start(:first)
      .edge(:first, :last)
      .finish(:last)

    error = assert_raises(ArgumentError) { graph.validate! }

    assert_includes error.message, "retry_on"
  end

  def test_rejects_orphan_ambiguous_and_nested_joins
    orphan = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :second, :second
      node :last, :last
      start :first
      edge :first, :second
      join [:first, :second], to: :last
      finish :last
    end
    assert_raises(LittleGhost::ConfigurationError) { orphan.validate! }

    ambiguous = Class.new(LittleGhost::Graph) do
      node :start, :start
      node :left, :left
      node :right, :right
      node :first_join, :first_join
      node :second_join, :second_join
      start :start
      fork :start, to: [:left, :right]
      join [:left, :right], to: :first_join
      join [:left, :right], to: :second_join
      finish :first_join
    end
    assert_raises(LittleGhost::ConfigurationError) { ambiguous.validate! }

    nested = Class.new(LittleGhost::Graph) do
      node :start, :start
      node :left, :left
      node :right, :right
      node :nested, :nested
      node :nested_left, :nested_left
      node :nested_right, :nested_right
      node :left_done, :left_done
      node :done, :done
      start :start
      fork :start, to: [:left, :right]
      edge :left, :nested
      fork :nested, to: [:nested_left, :nested_right]
      join [:nested_left, :nested_right], to: :left_done
      join [:left_done, :right], to: :done
      finish :done
    end
    assert_raises(LittleGhost::ConfigurationError) { nested.validate! }
  end

  def test_reports_unrouted_failed_node_usage
    failure = RuntimeError.new("offline")
    graph_class = Class.new(LittleGhost::Graph) do
      node :answer, :answer
      start :answer
      finish :answer
    end
    runtime = Runtime.new(
      answer: [FakeAssembly.new(failure, failure_usage: LittleGhost::Usage.new(input_tokens: 7))]
    )
    events = []

    assert_raises(RuntimeError) do
      graph_class.new(run: Run.new(runtime), runtime:).stream("request").each { |event| events << event }
    end

    assert_equal 7, events.last.data.fetch(:usage).input_tokens
  end

  def test_mermaid_renders_parallel_and_error_routes
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      node :fallback, :fallback
      start :plan
      fork :plan, to: [:research, :verify]
      join [:research, :verify], to: :answer
      error_edge :research, :fallback, on: [RuntimeError]
      edge :fallback, :research
      finish :answer
    end

    mermaid = graph_class.to_mermaid

    assert_includes mermaid, "|fork|"
    assert_includes mermaid, "|join|"
    assert_includes mermaid, "-.->|error|"
  end

  private

  def result(text, input_tokens: 0)
    LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: text),
      stop_reason: :end_turn,
      usage: LittleGhost::Usage.new(input_tokens:),
      messages: [],
      state: {},
      structured_result: nil
    )
  end
end
