# frozen_string_literal: true

require "test_helper"

class WorkflowTest < Minitest::Test
  class FakeAgent
    attr_reader :calls

    def initialize(result, mutation: nil, failure_usage: LittleGhost::Usage.new, close_error: nil)
      @result = result
      @mutation = mutation
      @failure_usage = failure_usage
      @close_error = close_error
      @calls = []
    end

    def prompt_locals = {}

    def call(input, **options)
      calls << [:call, input, options]
      @mutation&.call(options.fetch(:context))
      raise @result if @result.is_a?(Exception)

      @result
    end

    def stream(input, **options)
      calls << [:stream, input, options]
      @mutation&.call(options.fetch(:context))

      Enumerator.new do |events|
        if @result.is_a?(Exception)
          events << LittleGhost::StreamEvent.build(
            :invocation_error,
            error: @result,
            usage: @failure_usage,
            metadata: {}
          )
          raise @result
        end
        events << LittleGhost::StreamEvent.build(:invocation_stop, result: @result)
      end
    end

    def close
      @closed = true
      raise @close_error if @close_error
    end

    def closed? = @closed == true
  end

  class Application
    attr_reader :built

    def initialize(agents)
      @agents = agents.transform_values(&:dup)
      @built = []
    end

    def build_agent(agent_class_or_name, run:)
      built << [agent_class_or_name, run]
      @agents.fetch(agent_class_or_name).shift ||
        raise("No fake #{agent_class_or_name} configured")
    end

    def template_locals(run:, agent:)
      {run:, agent:}
    end
  end

  Run = Struct.new(:runtime)

  class ExampleWorkflow < LittleGhost::Workflow
    attr_reader :route, :note

    private

    def perform
      @route = invoke(:router).output
      @note = invoke(:note).output
      invoke :main, input: "#{input.text}\n\nResearch:\n#{note}"
    end
  end

  def test_composes_structured_and_text_agents_then_streams_the_responder
    router = FakeAgent.new(
      result(structured: {"path" => "investigate"}, usage: LittleGhost::Usage.new(input_tokens: 2)),
      mutation: ->(state) { state["poisoned"] = true }
    )
    note = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 3)))
    main_result = result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5))
    main = FakeAgent.new(main_result)
    application = Application.new(router: [router], note: [note], main: [main])
    run = Run.new(application)
    workflow = ExampleWorkflow.new(run:)
    cancellation = LittleGhost::Support::CancellationToken.new
    deadline = Time.now + 60
    checkpoint = ->(**) {}
    history = [LittleGhost::Message.new(role: :assistant, content: "prior")]
    context = {"request_id" => "request-1"}

    events = workflow.stream(
      "question",
      history:,
      context:,
      settings: {temperature: 0.1},
      template_locals: {shared: "value", agent: "wrong"},
      template_paths: [],
      cancellation_token: cancellation,
      deadline:,
      parent_operation_id: "run-1",
      checkpoint:
    ).to_a

    assert_equal({"path" => "investigate"}, workflow.route)
    assert_equal "evidence", workflow.note
    assert_equal main_result.text, events.last.data.fetch(:result).text
    assert_equal 10, events.last.data.fetch(:result).usage.input_tokens
    refute context.key?("poisoned")
    assert router.closed?
    assert note.closed?
    assert main.closed?

    router_options = router.calls.first.fetch(2)
    refute_same context, router_options.fetch(:context)
    assert router_options.fetch(:context).fetch("poisoned")
    assert_same cancellation, router_options.fetch(:cancellation_token)
    assert_equal deadline, router_options.fetch(:deadline)
    assert_equal "run-1", router_options.fetch(:parent_operation_id)
    assert_same router, router_options.dig(:template_locals, :agent)
    assert_equal "value", router_options.dig(:template_locals, :shared)

    operation, final_input, final_options = main.calls.first
    assert_equal :stream, operation
    assert_equal "question\n\nResearch:\nevidence", final_input
    assert_equal %w[prior], final_options.fetch(:history).map(&:text)
    refute final_options.fetch(:context).key?("poisoned")
    assert_equal({temperature: 0.1}, final_options.fetch(:settings))
    assert_same checkpoint, final_options.fetch(:checkpoint)
    assert_same main, final_options.dig(:template_locals, :agent)
    assert_equal "value", final_options.dig(:template_locals, :shared)

    assert_raises(LittleGhost::Error) { workflow.stream("again") }
    workflow.close
    workflow.close
  end

  def test_closes_an_intermediate_agent_when_it_fails
    error = RuntimeError.new("failed")
    router = FakeAgent.new(error, failure_usage: LittleGhost::Usage.new(input_tokens: 7))
    application = Application.new(router: [router])
    workflow = ExampleWorkflow.new(run: Run.new(application))
    events = []

    caught = assert_raises(RuntimeError) do
      workflow.stream("question").each { |event| events << event }
    end

    assert_same error, caught
    assert_equal :invocation_error, events.last.type
    assert_equal 7, events.last.data.fetch(:usage).input_tokens
    assert router.closed?
  end

  def test_requires_perform_to_return_the_final_invocation
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = "not a response"
    end
    workflow = workflow_class.new(run: Run.new(Application.new({})))

    error = assert_raises(LittleGhost::ProtocolError) { workflow.stream("question").to_a }

    assert_includes error.message, "final invoke"
  end

  def test_preserves_final_usage_when_final_agent_cleanup_fails
    cleanup_error = RuntimeError.new("cleanup failed")
    router = FakeAgent.new(result(structured: {"path" => "investigate"}, usage: LittleGhost::Usage.new(input_tokens: 2)))
    note = FakeAgent.new(result(text: "evidence", usage: LittleGhost::Usage.new(input_tokens: 3)))
    main = FakeAgent.new(
      result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5)),
      close_error: cleanup_error
    )
    workflow = ExampleWorkflow.new(
      run: Run.new(Application.new(router: [router], note: [note], main: [main]))
    )
    events = []

    caught = assert_raises(RuntimeError) do
      workflow.stream("question").each { |event| events << event }
    end

    assert_same cleanup_error, caught
    assert_equal %i[invocation_stop invocation_error], events.map(&:type)
    assert_equal 10, events.last.data.fetch(:usage).input_tokens
  end

  def test_tool_stop_result_is_not_treated_as_usage_observation
    final_result = result(text: "final", usage: LittleGhost::Usage.new(input_tokens: 5))
    tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "inspect", input: {})
    tool_result = LittleGhost::Content::ToolResult.new(
      tool_use_id: tool_use.id,
      content: "found",
      status: :success
    )
    agent = FakeAgent.new(final_result)
    agent.define_singleton_method(:stream) do |input, **options|
      calls << [:stream, input, options]
      [
        LittleGhost::StreamEvent.build(:tool_stop, tool_use:, result: tool_result),
        LittleGhost::StreamEvent.build(:invocation_stop, result: final_result)
      ].each
    end
    workflow_class = Class.new(LittleGhost::Workflow) do
      private

      def perform = invoke(:main)
    end
    workflow = workflow_class.new(run: Run.new(Application.new(main: [agent])))

    events = workflow.stream("question").to_a

    assert_equal %i[tool_stop invocation_stop], events.map(&:type)
    assert_same tool_result, events.first.data.fetch(:result)
    assert_equal 5, events.last.data.fetch(:result).usage.input_tokens
  end

  private

  def result(text: nil, structured: nil, usage: LittleGhost::Usage.new)
    LittleGhost::RunResult.new(
      message: LittleGhost::Message.new(role: :assistant, content: text || "structured"),
      stop_reason: structured ? :structured_result : :end_turn,
      usage:,
      messages: [],
      state: {},
      structured_result: structured && LittleGhost::StructuredResult.new(
        schema_name: "test",
        value: structured
      )
    )
  end
end
