# frozen_string_literal: true

require "test_helper"
require "async"

class GraphTest < Minitest::Test
  class FakeAssembly
    attr_reader :calls

    def initialize(result, failure_usage: LittleGhost::Usage.new, mutation: nil)
      @result = result
      @failure_usage = failure_usage
      @mutation = mutation
      @calls = []
    end

    def stream(input, **options)
      calls << [input, options]
      @mutation&.call
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

    attr_reader :task_runner

    def initialize(assemblies = nil, task_runner: LittleGhost::Support::TaskRunner.new, **assembly_keywords)
      assemblies ||= assembly_keywords
      @assemblies = assemblies.transform_values(&:dup)
      @built = []
      @task_runner = task_runner
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
    assert_includes refund.calls.first.first.text, "From classify:\nrefund"
    assert_includes answer.calls.first.first.text, "From refund:\napproved"
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
      edge :plan, [:research, :verify], max_concurrency: 2
      edge [:research, :verify], :answer
      finish :answer
    end
    plan = FakeAssembly.new(result("plan", input_tokens: 1))
    research = FakeAssembly.new(result("facts", input_tokens: 2))
    verify = FakeAssembly.new(result("checked", input_tokens: 3))
    answer = FakeAssembly.new(result("done", input_tokens: 4))
    runtime = Runtime.new(plan: [plan], research: [research], verify: [verify], answer: [answer])

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    final = events.find { |event| event.type == :invocation_stop }.data.fetch(:result)

    assert_includes events.map(&:type), :assembly_fork
    assert_includes events.map(&:type), :assembly_join
    assert_equal %w[plan research verify answer], final.steps.map(&:participant)
    assert_equal 10, final.usage.input_tokens
    assert_equal <<~TEXT.chomp, research.calls.first.first.text
      Original Task:
      request

      Inputs from previous nodes:

      From plan:
      plan
    TEXT
    assert_equal research.calls.first.first.text, verify.calls.first.first.text
    answer_input = answer.calls.first.first.text
    assert_equal <<~TEXT.chomp, answer_input
      Original Task:
      request

      Inputs from previous nodes:

      From research:
      facts

      From verify:
      checked
    TEXT

    steps = final.steps.to_h { |step| [step.participant, step] }
    assert_equal [steps.fetch("plan").id], steps.fetch("research").predecessor_ids
    assert_equal [steps.fetch("plan").id], steps.fetch("verify").predecessor_ids
    assert_equal(
      [steps.fetch("research").id, steps.fetch("verify").id].sort,
      steps.fetch("answer").predecessor_ids.sort
    )
  end

  def test_fork_branches_use_scheduler_fibers
    workers = Queue.new
    capture_worker = lambda do
      workers << [Thread.current.object_id, Fiber.current.object_id, Fiber.blocking?]
      Async::Task.current.yield
    end
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, [:research, :verify], max_concurrency: 2
      edge [:research, :verify], :answer
      finish :answer
    end
    runtime = Runtime.new(
      {
        plan: [FakeAssembly.new(result("plan"))],
        research: [FakeAssembly.new(result("facts"), mutation: capture_worker)],
        verify: [FakeAssembly.new(result("checked"), mutation: capture_worker)],
        answer: [FakeAssembly.new(result("done"))]
      },
      task_runner: LittleGhost::Support::TaskRunner.new(backend: :auto)
    )

    Async do
      graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a
    end.wait

    contexts = 2.times.map { workers.pop }
    assert_equal 1, contexts.map(&:first).uniq.length
    assert_equal 2, contexts.map { |context| context.fetch(1) }.uniq.length
    assert contexts.none?(&:last)
  end

  def test_fan_in_input_mapper_replaces_the_default_input
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, [:research, :verify]
      edge(
        [:research, :verify], :answer,
        input: ->(state) { "#{state.incoming_results.fetch(:research).output} + #{state.incoming_results.fetch(:verify).output}" }
      )
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research: [FakeAssembly.new(result("facts"))],
      verify: [FakeAssembly.new(result("checked"))],
      answer: [answer]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "facts + checked", answer.calls.first.first
  end

  def test_infers_fan_out_and_fan_in_from_scalar_edges
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, :research
      edge :plan, :verify
      edge :research, :answer
      edge :verify, :answer
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research: [FakeAssembly.new(result("facts"))],
      verify: [FakeAssembly.new(result("checked"))],
      answer: [answer]
    )

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_includes events.map(&:type), :assembly_fork
    assert_includes events.map(&:type), :assembly_join
    assert_includes answer.calls.first.first.text, "From research:\nfacts"
    assert_includes answer.calls.first.first.text, "From verify:\nchecked"
  end

  def test_infers_fan_in_after_uneven_branch_paths
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :edit, :edit
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, :research
      edge :plan, :verify
      edge :research, :edit
      edge :edit, :answer
      edge :verify, :answer
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research: [FakeAssembly.new(result("facts"))],
      edit: [FakeAssembly.new(result("edited"))],
      verify: [FakeAssembly.new(result("checked"))],
      answer: [answer]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_includes answer.calls.first.first.text, "From edit:\nedited"
    assert_includes answer.calls.first.first.text, "From verify:\nchecked"
  end

  def test_node_mapper_receives_immediate_results_and_edge_mapper_takes_precedence
    observed = []
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last, input: lambda { |state|
        observed << [state.previous, state.predecessors, state.incoming_results.keys]
        "node mapped"
      }
      start :first
      edge :first, :last, input: ->(_state) { "edge mapped" }
      finish :last
    end
    last = FakeAssembly.new(result("done"))
    runtime = Runtime.new(first: [FakeAssembly.new(result("evidence"))], last: [last])

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "edge mapped", last.calls.first.first
    assert_empty observed

    node_mapped = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last, input: lambda { |state|
        observed << [state.previous, state.predecessors, state.incoming_results.keys]
        "node mapped"
      }
      start :first
      edge :first, :last
      finish :last
    end
    last = FakeAssembly.new(result("done"))
    runtime = Runtime.new(first: [FakeAssembly.new(result("evidence"))], last: [last])

    node_mapped.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "node mapped", last.calls.first.first
    assert_equal [[:first, [:first], [:first]]], observed
  end

  def test_inferred_fan_out_keeps_each_edge_input_mapper
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, :research, input: ->(state) { "research: #{state.previous_result.output}" }
      edge :plan, :verify, input: ->(state) { "verify: #{state.previous_result.output}" }
      edge [:research, :verify], :answer
      finish :answer
    end
    research = FakeAssembly.new(result("facts"))
    verify = FakeAssembly.new(result("checked"))
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))], research: [research], verify: [verify],
      answer: [FakeAssembly.new(result("done"))]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "research: plan", research.calls.first.first
    assert_equal "verify: plan", verify.calls.first.first
  end

  def test_fan_in_node_mapper_receives_all_immediate_results
    observed = nil
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer, input: lambda { |state|
        observed = [state.previous, state.predecessors, state.incoming_results.transform_values(&:output)]
        "mapped fan-in"
      }
      start :plan
      edge :plan, :research
      edge :plan, :verify
      edge :research, :answer
      edge :verify, :answer
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(
      plan: [FakeAssembly.new(result("plan"))],
      research: [FakeAssembly.new(result("facts"))],
      verify: [FakeAssembly.new(result("checked"))],
      answer: [answer]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    assert_equal "mapped fan-in", answer.calls.first.first
    assert_nil observed.fetch(0)
    assert_equal [:research, :verify], observed.fetch(1)
    assert_equal({research: "facts", verify: "checked"}, observed.fetch(2))
  end

  def test_default_input_preserves_original_content_blocks_and_metadata
    graph_class = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :last, :last
      start :first
      edge :first, :last
      finish :last
    end
    image = LittleGhost::Content::Image.new(data: "image", media_type: "image/png")
    input = LittleGhost::Message.new(
      role: :user,
      content: [LittleGhost::Content::Text.new(text: "request"), image],
      metadata: {request_id: "one"}
    )
    last = FakeAssembly.new(result("done"))
    runtime = Runtime.new(first: [FakeAssembly.new(result("evidence"))], last: [last])

    graph_class.new(run: Run.new(runtime), runtime:).stream(input).to_a

    routed = last.calls.first.first
    assert_equal image, routed.content.fetch(2)
    refute_same image, routed.content.fetch(2)
    assert_equal "one", routed.metadata[:request_id]
    assert_equal "Original Task:\nrequest\n\nInputs from previous nodes:\n\nFrom first:\nevidence", routed.text
  end

  def test_parallel_mapper_state_is_detached_and_deeply_immutable
    mutation_errors = Queue.new
    observations = Queue.new
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, :research, input: lambda { |state|
        [
          -> { state.input.content.first.text.replace("changed") },
          -> { state.input.metadata[:nested] << "changed" },
          -> { state.previous_result.message.content.first.text.replace("changed") }
        ].each do |mutation|
          mutation.call
        rescue => error
          mutation_errors << error.class
        end
        "research"
      }
      edge :plan, :verify, input: lambda { |state|
        observations << [state.input.text, state.input.metadata[:nested], state.previous_result.text]
        "verify"
      }
      edge [:research, :verify], :answer
      finish :answer
    end
    request_text = +"request"
    metadata = {nested: ["original"]}
    input = LittleGhost::Message.new(role: :user, content: request_text, metadata:)
    plan_text = +"plan"
    plan_result = result(plan_text)
    runtime = Runtime.new(
      plan: [FakeAssembly.new(plan_result)],
      research: [FakeAssembly.new(result("facts"))],
      verify: [FakeAssembly.new(result("checked"))],
      answer: [FakeAssembly.new(result("done"))]
    )

    graph_class.new(run: Run.new(runtime), runtime:).stream(input).to_a

    assert_equal [FrozenError, FrozenError, FrozenError], 3.times.map { mutation_errors.pop }
    assert_equal ["request", ["original"], "plan"], observations.pop
    assert_equal "request", input.text
    assert_equal ["original"], input.metadata[:nested]
    assert_equal "plan", plan_result.text
  end

  def test_graph_and_group_concurrency_defaults_compile_into_fan_outs
    graph_class = Class.new(LittleGhost::Graph) do
      max_concurrency 3
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, [:research, :verify], max_concurrency: 1
      edge [:research, :verify], :answer
      finish :answer
    end

    fork = graph_class.graph_definition!.fetch(3).first

    assert_equal 1, fork.max_concurrency
    assert_equal 3, graph_class.max_concurrency
  end

  def test_conditional_group_is_one_exclusive_route_with_a_scalar_fallback
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, [:research, :verify], if: ->(state) { state.result(:plan).output == "parallel" }
      edge :plan, :answer
      edge [:research, :verify], :answer
      finish :answer
    end
    answer = FakeAssembly.new(result("done"))
    runtime = Runtime.new(plan: [FakeAssembly.new(result("direct"))], answer: [answer])

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    refute_includes events.map(&:type), :assembly_fork
    assert_equal %i[assembly_step_start assembly_step_stop assembly_transition assembly_step_start assembly_step_stop
      text_delta invocation_stop], events.map(&:type)
    assert_includes answer.calls.first.first.text, "From plan:\ndirect"
  end

  def test_inferred_fan_in_edges_remain_available_to_non_parallel_routes
    graph_class = Class.new(LittleGhost::Graph) do
      node :start_node, :start_node
      node :parallel, :parallel
      node :other, :other
      node :left, :left
      node :right, :right
      node :done, :done
      start :start_node
      edge :start_node, :parallel, if: ->(state) { state.result(:start_node).output == "parallel" }
      edge :start_node, :other
      edge :parallel, :left
      edge :parallel, :right
      edge :left, :done
      edge :right, :done
      edge :other, :left
      finish :done
    end
    done = FakeAssembly.new(result("finished"))
    runtime = Runtime.new(
      start_node: [FakeAssembly.new(result("direct"))],
      other: [FakeAssembly.new(result("other"))],
      left: [FakeAssembly.new(result("left"))],
      done: [done]
    )

    events = graph_class.new(run: Run.new(runtime), runtime:).stream("request").to_a

    refute_includes events.map(&:type), :assembly_fork
    assert_includes done.calls.first.first.text, "From left:\nleft"
  end

  def test_rejects_input_mappers_on_scalar_edges_consumed_by_inferred_fan_in
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, :research
      edge :plan, :verify
      edge :research, :answer, input: ->(_state) { "research" }
      edge :verify, :answer
      finish :answer
    end

    error = assert_raises(LittleGhost::ConfigurationError) { graph_class.validate! }

    assert_includes error.message, "target node"
    assert_includes error.message, "array-source edge"
  end

  def test_rejects_conditional_edges_consumed_by_inferred_fan_in
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :left, :left
      node :right, :right
      node :done, :done
      start :plan
      edge :plan, :left
      edge :plan, :right
      edge :left, :done, if: ->(_state) { false }
      edge :right, :done
      finish :done
    end

    error = assert_raises(LittleGhost::ConfigurationError) { graph_class.validate! }

    assert_includes error.message, "conditional incoming edges"
    assert_includes error.message, "before its fan-in predecessor"
  end

  def test_rejects_inferred_fan_in_when_a_predecessor_has_an_alternate_route
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :left, :left
      node :right, :right
      node :detour, :detour
      node :done, :done
      start :plan
      edge :plan, :left
      edge :plan, :right
      edge :left, :detour, if: ->(_state) { true }
      edge :left, :done
      edge :detour, :detour
      edge :right, :done
      finish :done
    end

    error = assert_raises(LittleGhost::ConfigurationError) { graph_class.validate! }

    assert_includes error.message, "another successful route"
    assert_includes error.message, "route the branch"
  end

  def test_max_steps_is_shared_across_parallel_branches
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research, :research
      node :verify, :verify
      node :answer, :answer
      start :plan
      edge :plan, [:research, :verify], max_concurrency: 2
      edge [:research, :verify], :answer
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

  def test_fan_out_branches_follow_edges_to_their_fan_in_sources
    graph_class = Class.new(LittleGhost::Graph) do
      node :plan, :plan
      node :research_start, :research_start
      node :research_done, :research_done
      node :verify_start, :verify_start
      node :verify_done, :verify_done
      node :answer, :answer
      start :plan
      edge :plan, [:research_start, :verify_start]
      edge :research_start, :research_done
      edge :verify_start, :verify_done
      edge [:research_done, :verify_done], :answer
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

  def test_rejects_orphan_ambiguous_and_nested_fan_ins
    orphan = Class.new(LittleGhost::Graph) do
      node :first, :first
      node :second, :second
      node :last, :last
      start :first
      edge :first, :second
      edge [:first, :second], :last
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
      edge :start, [:left, :right]
      edge [:left, :right], :first_join
      edge [:left, :right], :second_join
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
      edge :start, [:left, :right]
      edge :left, :nested
      edge :nested, [:nested_left, :nested_right]
      edge [:nested_left, :nested_right], :left_done
      edge [:left_done, :right], :done
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
      edge :plan, [:research, :verify]
      edge [:research, :verify], :answer
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
