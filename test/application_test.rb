# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"
require "little_ghost/ag_ui"

class ApplicationTest < Minitest::Test
  class ScriptedProvider
    attr_reader :requests

    def initialize(text = "Done")
      @text = text
      @requests = []
    end

    def stream(request)
      @requests << request
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: @text),
        stop_reason: :end_turn,
        usage: LittleGhost::Usage.new(input_tokens: 1, output_tokens: 1)
      )
      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: @text),
        LittleGhost::StreamEvent.build(:message_stop, response:),
        LittleGhost::StreamEvent.build(:usage, usage: response.usage)
      ].each
    end
  end

  class ProgressThenDeadlineProvider
    def initialize(error = LittleGhost::DeadlineExceededError.new("deadline"))
      @turn = 0
      @error = error
    end

    def stream(_request)
      @turn += 1
      raise @error if @turn == 3

      text = "Progress #{@turn}"
      tool_use = LittleGhost::Content::ToolUse.new(
        id: "tool-#{@turn}",
        name: "continue_work",
        input: {}
      )
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: [text, tool_use]),
        stop_reason: :tool_use,
        usage: LittleGhost::Usage.new(input_tokens: @turn, output_tokens: 1)
      )
      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text:),
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  class ProgressThenRetryDeadlineProvider
    def initialize(complete_failed_attempt:)
      @complete_failed_attempt = complete_failed_attempt
      @turn = 0
    end

    def stream(_request)
      @turn += 1
      return completed_progress_turn if @turn == 1

      Enumerator.new do |events|
        events << LittleGhost::StreamEvent.build(:message_start)
        events << LittleGhost::StreamEvent.build(:text_delta, text: "Discarded retry text")
        if @complete_failed_attempt
          response = LittleGhost::ModelResponse.new(
            message: LittleGhost::Message.new(role: :assistant, content: "Discarded retry response"),
            stop_reason: :end_turn
          )
          events << LittleGhost::StreamEvent.build(:message_stop, response:)
        end
        events << LittleGhost::StreamEvent.build(:model_retry, attempt: 1, delay: 0)
        raise LittleGhost::DeadlineExceededError, "deadline"
      end
    end

    private

    def completed_progress_turn
      tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "continue_work", input: {})
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: ["Stable progress", tool_use]),
        stop_reason: :tool_use
      )
      [
        LittleGhost::StreamEvent.build(:message_start),
        LittleGhost::StreamEvent.build(:text_delta, text: "Stable progress"),
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  class FailingProvider
    def initialize(error)
      @error = error
    end

    def stream(_request)
      raise @error
    end
  end

  class StubbornProvider
    attr_reader :cleanup_started, :producer_started, :release

    def initialize
      @cleanup_started = Queue.new
      @producer_started = Queue.new
      @release = Queue.new
    end

    def stream(request)
      Enumerator.new do |events|
        stream = LittleGhost::Support::InterruptibleStream.new(
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        ) do
          producer_started << Thread.current
          Queue.new.pop
        ensure
          cleanup_started << true
          release.pop
        end
        stream.each { |event| events << event }
      end
    end
  end

  class ReasoningThenAnswerProvider
    attr_reader :requests

    def initialize
      @requests = []
    end

    def stream(request)
      @requests << request
      if requests.length == 1
        tool_use = LittleGhost::Content::ToolUse.new(id: "tool-1", name: "continue_work", input: {})
        response = LittleGhost::ModelResponse.new(
          message: LittleGhost::Message.new(role: :assistant, content: [
            LittleGhost::Content::Reasoning.new(
              text: "private tool reasoning",
              details: [{"type" => "reasoning.text", "index" => 0, "text" => "private signed reasoning"}]
            ),
            tool_use
          ]),
          stop_reason: :tool_use
        )
        events = [LittleGhost::StreamEvent.build(:reasoning_delta, text: "private tool reasoning")]
      else
        response = LittleGhost::ModelResponse.new(
          message: LittleGhost::Message.new(role: :assistant, content: [
            LittleGhost::Content::Reasoning.new(text: "private answer reasoning"),
            LittleGhost::Content::Text.new(text: "Done")
          ]),
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new(output_tokens: 1, reasoning_tokens: 2)
        )
        events = [
          LittleGhost::StreamEvent.build(:reasoning_delta, text: "private answer reasoning"),
          LittleGhost::StreamEvent.build(:text_delta, text: "Done")
        ]
      end
      [
        LittleGhost::StreamEvent.build(:message_start),
        *events,
        LittleGhost::StreamEvent.build(:message_stop, response:)
      ].each
    end
  end

  def test_minimal_application_resolves_root_agent_prompt_and_model
    with_application do |application, provider, root|
      run = application.call(message: "Build it")

      assert run.completed?
      assert_equal "Done", run.response
      assert_equal Pathname.new(File.realpath(root)), application.root
      assert_equal "Prompt for Build it", provider.requests.first.messages.first.text
      assert_same application, run.application
    end
  end

  def test_stream_is_generic_and_call_returns_the_run
    with_application do |application|
      events = application.stream(message: "Build it").to_a

      assert_equal :run_start, events.first.type
      assert_equal :run_stop, events.last.type
      assert_includes events.map(&:type), :text_delta
      assert events.all? { |event| event.is_a?(LittleGhost::StreamEvent) }
    end
  end

  def test_partial_run_uses_the_latest_assistant_message_instead_of_concatenating_progress
    agent = progress_agent

    with_application(agent:, provider: ProgressThenDeadlineProvider.new) do |application|
      run = application.call(message: "Build it", session_id: "conversation")

      assert run.partial?
      assert_equal "Progress 2", run.response
      assert_equal 5, run.usage.total_tokens
      assert_equal %i[user assistant tool assistant tool], run.session.history.map(&:role)
      assert_equal ["Build it", "Progress 1", "", "Progress 2", ""], run.session.history.map(&:text)
    end
  end

  def test_partial_run_discards_text_and_closed_responses_from_a_retried_attempt
    [false, true].each do |complete_failed_attempt|
      provider = ProgressThenRetryDeadlineProvider.new(complete_failed_attempt:)

      with_application(agent: progress_agent, provider:) do |application|
        run = application.call(message: "Build it", session_id: "conversation")

        assert run.partial?
        assert_equal "Stable progress", run.response
        refute_includes run.response, "Discarded"
      end
    end
  end

  def test_cancelled_run_checkpoints_completed_turns
    provider = ProgressThenDeadlineProvider.new(LittleGhost::CancelledError.new("cancelled"))

    with_application(agent: progress_agent, provider:) do |application|
      run = application.call(message: "Build it", session_id: "conversation")

      assert run.cancelled?
      assert_equal 5, run.usage.total_tokens
      assert_equal %i[user assistant tool assistant tool], run.session.history.map(&:role)
      tool_ids = run.session.history.flat_map { |message|
        message.content.grep(LittleGhost::Content::ToolUse).map(&:id)
      }
      assert_equal %w[tool-1 tool-2], tool_ids
    end
  end

  def test_failed_run_checkpoints_completed_turns
    provider = ProgressThenDeadlineProvider.new(LittleGhost::ProviderError.new("offline"))

    with_application(agent: progress_agent, provider:) do |application|
      run = application.call(message: "Build it", session_id: "conversation")

      assert run.failed?
      assert_equal 5, run.usage.total_tokens
      assert_equal %i[user assistant tool assistant tool], run.session.history.map(&:role)
      assert_equal "Progress 2", run.session.history.fetch(3).text
    end
  end

  def test_abnormal_runs_report_cumulative_usage_once_end_to_end
    {
      LittleGhost::CancelledError.new("cancelled") => [:cancelled, :run_cancel],
      LittleGhost::ProviderError.new("offline") => [:failed, :run_error]
    }.each do |error, (expected_outcome, expected_terminal)|
      recorded = []
      instrumentation = LittleGhost::Support::Instrumentation.new
      instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })
      provider = ProgressThenDeadlineProvider.new(error)

      with_application(agent: progress_agent, provider:, instrumentation:) do |application|
        run = application.build_run(message: "Build it", session_id: "conversation")
        source_events = run.to_a
        translated = LittleGhost::AGUI::Adapter.new
          .stream(source_events, thread_id: "conversation", run_id: run.invocation.run_id)
          .to_a

        assert run.public_send("#{expected_outcome}?")
        assert_equal 5, run.usage.total_tokens
        assert_equal 1, source_events.count { |event| event.type == :invocation_error }
        assert_equal 5, source_events.find { |event| event.type == :invocation_error }
          .data.fetch(:usage).total_tokens
        assert_equal expected_terminal, source_events.last.type

        agent_stop = recorded.reverse.find { |name, _attributes| name == :agent_stop }.last
        run_stop = recorded.reverse.find { |name, _attributes| name == :run_stop }.last
        assert_equal 5, agent_stop.fetch(:total_tokens)
        assert_equal 5, run_stop.fetch(:total_tokens)
        assert_equal expected_outcome, run_stop.fetch(:outcome)

        usage_events = translated.select { |event| event[:name] == "little_ghost.usage" }
        assert_equal 1, usage_events.length
        assert_equal 5, usage_events.first.dig(:value, :usage, :total_tokens)
      end
    end
  end

  def test_known_model_failures_have_stable_safe_terminal_messages
    failures = {
      LittleGhost::ToolLoopError.new("Stopped after detecting a repeated tool-call loop in \"lookup\".") =>
        "Stopped after detecting a repeated tool-call loop in \"lookup\".",
      LittleGhost::OutputLimitError.new("raw output details") =>
        "The model reached its output limit before completing a response. Please retry with a narrower request.",
      LittleGhost::MalformedToolCallError.new("raw malformed arguments") =>
        "The model returned an invalid tool call before completing the response. Please retry with a narrower request."
    }

    failures.each do |error, expected|
      with_application(provider: FailingProvider.new(error)) do |application|
        terminal = application.stream(message: "Build it").to_a.last

        assert_equal :run_error, terminal.type
        assert_equal expected, terminal.data.fetch(:message)
        refute_includes terminal.data.fetch(:message), "raw"
      end
    end
  end

  def test_deadline_is_propagated_to_the_model_request
    deadline = Time.now + 60
    with_application do |application, provider|
      application.call(message: "Build it", deadline_at: deadline)

      assert_equal deadline, provider.requests.first.deadline
    end
  end

  def test_framework_emits_correlated_semantic_telemetry_without_ui_deltas
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })

    with_application(instrumentation:) do |application|
      application.call(message: "Build it")
    end

    names = recorded.map(&:first)
    assert_equal %i[
      run_start agent_start agent_turn_start model_start model_stop agent_turn_stop agent_stop run_stop
    ], names

    run_start = recorded.assoc(:run_start).last
    run_stop = recorded.assoc(:run_stop).last
    agent_start = recorded.assoc(:agent_start).last
    turn_start = recorded.assoc(:agent_turn_start).last
    model_start = recorded.assoc(:model_start).last
    model_stop = recorded.assoc(:model_stop).last
    assert_equal run_start[:operation_id], run_stop[:operation_id]
    assert_equal run_start[:operation_id], agent_start[:parent_operation_id]
    assert_empty agent_start[:available_tools]
    assert_equal agent_start[:operation_id], turn_start[:parent_operation_id]
    assert_equal turn_start[:operation_id], model_start[:parent_operation_id]
    assert_equal model_start[:operation_id], model_stop[:operation_id]
    assert_kind_of Numeric, model_stop[:time_to_first_token]
    assert_equal run_start.values_at(:run_id, :invocation_id, :session_id),
      model_stop.values_at(:run_id, :invocation_id, :session_id)
    assert_equal :completed, run_stop[:outcome]
    assert_equal 2, run_stop[:total_tokens]
    assert_kind_of Numeric, run_stop[:duration_ms]
    refute_includes names, :message_start
    refute model_stop.key?(:response)
  end

  def test_run_telemetry_captures_session_input_and_output
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })

    with_application(instrumentation:) do |application|
      application.call(message: "Build it", session_id: "session-1")
    end

    run_start = recorded.assoc(:run_start).last
    run_stop = recorded.assoc(:run_stop).last
    assert_equal "session-1", run_start.fetch(:session_id)
    assert_equal "Build it", JSON.parse(run_start.fetch(:diagnostic_input))
    assert_equal "Done", JSON.parse(run_stop.fetch(:diagnostic_output))
  end

  def test_run_telemetry_never_captures_provider_reasoning_artifacts
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })
    message = LittleGhost::Message.new(
      role: :assistant,
      content: LittleGhost::Content::Reasoning.new(
        signature: "provider-signature",
        details: [{"type" => "provider", "provider_state" => "continuity"}],
        text: "visible reasoning"
      )
    )

    with_application(instrumentation:) do |application|
      application.call(message:)
    end

    captured = JSON.parse(recorded.assoc(:run_start).last.fetch(:diagnostic_input))
    assert_equal "visible reasoning", captured.dig("content", 0, "text")
    refute_includes JSON.generate(captured), "provider-signature"
    refute_includes JSON.generate(captured), "continuity"
  end

  def test_model_failure_before_output_omits_time_to_first_token
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new
    instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })

    with_application(provider: FailingProvider.new(LittleGhost::ProviderError.new("offline")), instrumentation:) do |application|
      application.call(message: "Build it")
    end

    model_stop = recorded.assoc(:model_stop).last
    assert_equal :error, model_stop[:outcome]
    refute model_stop.key?(:time_to_first_token)
  end

  def test_application_is_host_neutral_and_uses_generic_instrumentation_by_default
    with_application do |application|
      refute_respond_to application, :hosted
      refute_respond_to application.class, :rack_app
      assert_instance_of LittleGhost::Support::Instrumentation, application.instrumentation
    end
  end

  def test_default_model_names_are_normalized_to_strings
    application = Class.new(LittleGhost::Application)

    application.default_model :support

    assert_equal "support", application.default_model
  end

  def test_instrument_dsl_installs_providers_on_application_instrumentation
    installed = []
    installer = Module.new do
      define_singleton_method(:install) do |instrumentation:, service_name:, endpoint:|
        installed << [instrumentation, service_name, endpoint]
      end
    end

    with_application(configure: ->(application) { application.instrument installer, endpoint: "https://example.test" }) do |application|
      assert_same application.instrumentation, installed.first[0]
      assert_equal "https://example.test", installed.first[2]
    end
  end

  def test_instrument_dsl_instantiates_provider_classes_at_boot
    installed = []
    installer = Class.new do
      define_method(:install) do |instrumentation:, service_name:, label:|
        installed << [instrumentation, service_name, label]
      end
    end

    with_application(configure: ->(application) { application.instrument installer, label: "runtime" }) do |application|
      assert_same application.instrumentation, installed.first[0]
      assert_equal "runtime", installed.first[2]
    end
  end

  def test_instrument_dsl_accepts_classes_with_an_install_entrypoint
    installed = []
    installer = Class.new do
      define_singleton_method(:install) do |instrumentation:, service_name:|
        installed << [instrumentation, service_name]
      end

      def initialize = raise("the installer class should be used directly")
    end

    with_application(configure: ->(application) { application.instrument installer }) do |application|
      assert_same application.instrumentation, installed.first[0]
    end
  end

  def test_instrumentation_service_name_can_be_configured
    installed = []
    installer = Module.new do
      define_singleton_method(:install) { |service_name:, **| installed << service_name }
    end

    with_application(configure: lambda { |application|
      application.service_name "support-agent"
      application.instrument installer
    }) { nil }

    assert_equal ["support-agent"], installed
  end

  def test_instrument_declaration_can_override_the_application_service_name
    installed = []
    installer = Module.new do
      define_singleton_method(:install) { |service_name:, **| installed << service_name }
    end

    with_application(configure: lambda { |application|
      application.service_name "support-agent"
      application.instrument installer, service_name: "support-worker"
    }) { nil }

    assert_equal ["support-worker"], installed
  end

  def test_application_uses_an_in_memory_session_store_by_default
    with_application do |application|
      assert_instance_of LittleGhost::SessionStores::Memory, application.session_store
    end
  end

  def test_session_store_dsl_accepts_a_store
    store = LittleGhost::SessionStores::Memory.new

    with_application(configure: ->(application) { application.session_store store }) do |application|
      assert_same store, application.session_store
    end
  end

  def test_session_store_dsl_accepts_a_lazy_factory_block
    store = LittleGhost::SessionStores::Memory.new

    with_application(configure: ->(application) { application.session_store { store } }) do |application|
      assert_same store, application.session_store
    end
  end

  def test_session_actor_can_be_resolved_from_the_invocation
    store = LittleGhost::SessionStores::Memory.new

    with_application(
      session_store: store,
      configure: ->(application) { application.session_actor { |invocation| invocation.session_id } }
    ) do |application|
      run = application.call(message: "Continue", session_id: "conversation", actor_id: "principal")

      assert_equal "principal", run.invocation.actor_id
      assert_raises(LittleGhost::Error) { store.load("conversation", actor_id: "principal") }
      assert_includes store.load("conversation", actor_id: "conversation").fetch(:messages).map(&:text), "Done"
    end
  end

  def test_agent_reads_open_invocation_data_and_receives_standard_prompt_locals
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt { |locals| "#{locals.fetch(:invocation)[:channel]}:#{locals.fetch(:run).invocation.message.text}" }
    end
    with_application(agent:) do |application, provider|
      application.call(message: "hello", channel: "slack")

      assert_equal "slack:hello", provider.requests.first.messages.first.text
    end
  end

  def test_invocation_model_profile_overrides_are_applied_by_models
    with_application(settings: {temperature: 0.1}) do |application, provider|
      application.call(
        message: "hello",
        model_profiles: {"main" => {"parameters" => {"temperature" => 0.7, "max_tokens" => 50}}}
      )

      assert_equal({temperature: 0.7, max_tokens: 50}, provider.requests.first.settings)
    end
  end

  def test_tool_classes_and_dynamic_resolvers_are_instantiated_for_the_run
    static_tool = Class.new(LittleGhost::Tool) do
      tool_name "static"
      description "Static tool"
    end
    dynamic_tool = Class.new(LittleGhost::Tool) do
      tool_name "dynamic"
      description "Dynamic tool"
    end
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      tools static_tool
      tools { |run| run.invocation[:dynamic] ? [dynamic_tool] : [] }
    end

    with_application(agent:) do |application, provider|
      run = application.build_run(message: "hello", dynamic: true)
      built_agent = application.build_agent(run:)

      assert_equal %w[static dynamic], built_agent.tool_registry.names
      assert built_agent.tool_registry.all? { |tool| tool.run }
    end
  end

  def test_run_closes_agent_tools
    tool = Class.new(LittleGhost::Tool) do
      tool_name "closable"
      description "Closable tool"

      class << self
        attr_accessor :closes
      end

      def close = self.class.closes = self.class.closes.to_i + 1
    end
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Prompt"
      tools tool
    end

    with_application(agent:) { |application| application.call(message: "hello") }

    assert_equal 1, tool.closes
  end

  def test_run_closes_resources_before_emitting_its_terminal_event
    order = []

    with_application do |application|
      run = application.build_run(message: "hello")
      run.register { order << :closed }
      run.each do |event|
        order << :terminal if %i[run_partial run_cancel run_stop run_error].include?(event.type)
      end
    end

    assert_equal %i[closed terminal], order
  end

  def test_cleanup_failure_replaces_success_with_a_failed_terminal_event
    events = []

    with_application do |application|
      run = application.build_run(message: "hello")
      run.register { raise "cleanup failed" }

      error = assert_raises(RuntimeError) { run.each { |event| events << event } }

      assert_equal "cleanup failed", error.message
      assert run.failed?
      assert_equal :run_error, events.last.type
      assert_equal "cleanup failed", events.last.data.fetch(:error).message
      assert events.last.data.fetch(:cleanup_failed)
    end
  end

  def test_cleanup_failure_cannot_emit_stale_success_when_error_formatting_fails
    events = []
    configure = lambda do |application_class|
      application_class.define_method(:error_message) { |_error, _run| raise "formatter failed" }
    end

    with_application(configure:) do |application|
      run = application.build_run(message: "hello")
      run.register { raise "cleanup failed" }

      error = assert_raises(RuntimeError) { run.each { |event| events << event } }
      terminal = events.select { |event| %i[run_partial run_cancel run_stop run_error].include?(event.type) }

      assert_equal "cleanup failed", error.message
      assert_equal [:run_error], terminal.map(&:type)
      assert terminal.first.data.fetch(:cleanup_failed)
      assert_equal "The run could not cleanly stop all work.", terminal.first.data.fetch(:message)
    end
  end

  def test_execution_cleanup_error_survives_terminal_consumer_failure
    cleanup_error = LittleGhost::CleanupError.new("work is still running")
    consumer_error = RuntimeError.new("terminal consumer failed")

    with_application(provider: FailingProvider.new(cleanup_error)) do |application|
      run = application.build_run(message: "hello")

      raised = assert_raises(LittleGhost::CleanupError) do
        run.each do |event|
          raise consumer_error if event.type == :run_error
        end
      end

      assert_same cleanup_error, raised
      assert_same cleanup_error, run.error
      assert run.failed?
    end
  end

  def test_execution_cleanup_error_survives_run_stop_instrumentation_failure
    cleanup_error = LittleGhost::CleanupError.new("work is still running")
    instrumentation = Object.new
    instrumentation.define_singleton_method(:trace_context) { |**| {} }
    instrumentation.define_singleton_method(:emit) do |name, **|
      raise "run stop instrumentation failed" if name == :run_stop
    end

    with_application(provider: FailingProvider.new(cleanup_error), instrumentation:) do |application|
      run = application.build_run(message: "hello")

      raised = assert_raises(LittleGhost::CleanupError) { run.call }

      assert_same cleanup_error, raised
      assert_same cleanup_error, run.error
    end
  end

  def test_run_close_prioritizes_cleanup_errors
    ordinary_error = RuntimeError.new("ordinary close failure")
    cleanup_error = LittleGhost::CleanupError.new("resource is still running")

    with_application do |application|
      run = application.build_run(message: "hello")
      run.register { raise cleanup_error }
      run.register { raise ordinary_error }

      raised = assert_raises(LittleGhost::CleanupError) { run.close }

      assert_same cleanup_error, raised
    end
  end

  def test_stubborn_model_producer_cannot_emit_a_cancelled_terminal_event
    assert_stubborn_producer_fails_run(:cancellation)
  end

  def test_stubborn_model_producer_cannot_emit_a_partial_terminal_event
    assert_stubborn_producer_fails_run(:deadline)
  end

  def test_delegated_agents_own_separate_declared_tools
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "shared"
      description "Shared tool"

      class << self
        attr_accessor :closes
      end

      def close = self.class.closes = self.class.closes.to_i + 1
    end
    child = Class.new(LittleGhost::Agent) do
      model "main"
      description "Child"
      system_prompt "Child"
      tools tool_class
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      tools tool_class
      agent_as_tool child
    end

    with_application(agent: parent) { |application| application.call(message: "hello") }

    assert_equal 2, tool_class.closes
  end

  def test_run_owns_an_agent_tool_child_when_its_wrapper_name_collides
    collision = LittleGhost::Tool.define(name: "delegate", description: "Existing tool") { "existing" }
    child = Class.new(LittleGhost::Agent) do
      agent_id "delegate"
      model "main"
      description "Child"
      system_prompt "Child"

      class << self
        attr_accessor :closes
      end

      def close
        self.class.closes = self.class.closes.to_i + 1
        super
      end
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      tools collision
      agent_as_tool child
    end

    with_application(agent: parent) { |application| application.call(message: "hello") }

    assert_equal 1, child.closes
  end

  def test_sessions_restore_history_and_persist_the_result
    store = LittleGhost::SessionStores::Memory.new
    store.replace(
      "conversation",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "Earlier")],
      state: {},
      metadata: {}
    )

    with_application(session_store: store) do |application, provider|
      application.call(message: "Continue", session_id: "conversation", actor_id: "actor")

      assert_includes provider.requests.first.messages.map(&:text), "Earlier"
      assert_includes store.load("conversation", actor_id: "actor").fetch(:messages).map(&:text), "Done"
    end
  end

  def test_model_reasoning_survives_same_run_continuation_but_not_the_session_checkpoint
    store = LittleGhost::SessionStores::Memory.new
    provider = ReasoningThenAnswerProvider.new

    with_application(agent: progress_agent, provider:, session_store: store) do |application|
      run = application.call(message: "Continue", session_id: "conversation", actor_id: "actor")

      continued_messages = provider.requests.fetch(1).messages
      continued_reasoning = continued_messages.flat_map(&:content).grep(LittleGhost::Content::Reasoning).fetch(0)
      assert_equal "private signed reasoning", continued_reasoning.details.dig(0, "text")
      assert_equal "Done", run.response

      persisted = store.load("conversation", actor_id: "actor").fetch(:messages)
      refute persisted.flat_map(&:content).any? { |block| block.is_a?(LittleGhost::Content::Reasoning) }
      refute_includes JSON.generate(persisted.map(&:to_h)), "private tool reasoning"
      refute_includes JSON.generate(persisted.map(&:to_h)), "private signed reasoning"
      refute_includes JSON.generate(persisted.map(&:to_h)), "private answer reasoning"
      assert persisted.flat_map(&:content).any? { |block| block.is_a?(LittleGhost::Content::ToolUse) }
      assert_equal "Done", persisted.last.text
    end
  end

  def test_stored_session_history_takes_precedence_over_invocation_history
    store = LittleGhost::SessionStores::Memory.new
    store.replace(
      "conversation",
      actor_id: "actor",
      messages: [LittleGhost::Message.new(role: :user, content: "Stored")],
      state: {},
      metadata: {}
    )

    with_application(session_store: store) do |application, provider|
      application.call(
        message: "Continue",
        history: [{role: :user, content: "Supplied"}],
        session_id: "conversation",
        actor_id: "actor"
      )

      texts = provider.requests.first.messages.map(&:text)
      assert_includes texts, "Stored"
      refute_includes texts, "Supplied"
    end
  end

  def test_session_save_failure_fails_the_run
    store = Class.new(LittleGhost::SessionStores::Memory) do
      def append(id, messages:, **options)
        raise "offline" if messages.any? { |message| message.role == :assistant }

        super
      end
    end.new
    recorded = []
    instrumentation = LittleGhost::Support::Instrumentation.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(->(name, attributes) { recorded << [name, attributes] })

    with_application(session_store: store, instrumentation:) do |application|
      run = application.call(message: "Continue")

      assert run.failed?
      assert_empty run.response
      assert_equal "offline", run.error.message
      run_stop = recorded.assoc(:run_stop).last
      assert_equal "Done", JSON.parse(run_stop.fetch(:diagnostic_output))
      exception = JSON.parse(run_stop.fetch(:diagnostic_exception))
      assert_equal "RuntimeError", exception.fetch("type")
      assert_equal "offline", exception.fetch("message")
    end
  end

  def test_build_replaces_services_without_mutating_boot_configuration
    with_application do |application|
      replacement_provider = ScriptedProvider.new("Replacement")
      replacement_models = models_for(replacement_provider)
      isolated = application.class.build(models: replacement_models)

      result = isolated.call(message: "hello")

      assert_equal "Replacement", result.response
      assert application.class.boot_configuration.frozen?
      refute_same application.models, isolated.models
    end
  end

  def test_build_can_override_external_services_before_the_application_boots
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/application.rb"), "# application fixture\n")
      agent = Class.new(LittleGhost::Agent) do
        model "main"
        system_prompt "Test"
      end
      installer = Module.new do
        def self.install(**) = raise("external instrumentation was installed")
      end
      application_class = Class.new(LittleGhost::Application)
      application_class.root root
      application_class.agent agent
      application_class.instrument installer
      application_class.session_store { raise "external sessions were initialized" }
      session_store = LittleGhost::SessionStores::Memory.new

      application = application_class.build(
        models: models_for(ScriptedProvider.new),
        session_store:,
        instrumentation: LittleGhost::Support::Instrumentation.new,
        instruments: []
      )

      assert_instance_of LittleGhost::Support::Instrumentation, application.instrumentation
      assert_same session_store, application.session_store
      refute application_class.instance_variable_defined?(:@booted_application)
    end
  end

  def test_preboot_build_and_later_boot_share_the_application_loader
    Dir.mktmpdir do |root|
      agent_path = File.join(root, "app/agents/probe_agent.rb")
      FileUtils.mkdir_p(File.dirname(agent_path))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/application.rb"), "# application fixture\n")
      File.write(agent_path, "class ProbeAgent < LittleGhost::Agent; end\n")
      application_class = Class.new(LittleGhost::Application)
      application_class.root root
      application_class.agent "ProbeAgent"

      built = application_class.build
      booted = application_class.boot!

      assert_same built.loader, booted.loader
    end
  end

  def test_build_creates_a_loader_for_an_overridden_root
    with_application do |application|
      Dir.mktmpdir do |other_root|
        FileUtils.mkdir_p(File.join(other_root, "config"))
        File.write(File.join(other_root, "config/application.rb"), "# alternate application\n")

        isolated = application.class.build(root: other_root)

        assert_equal File.realpath(other_root), isolated.root.to_s
        assert_equal File.realpath(other_root), isolated.loader.root
      end
    end
  end

  def test_builder_closes_eager_tools_when_dynamic_subagents_fail
    tool = Class.new(LittleGhost::Tool) do
      tool_name "resource"
      description "Resource"

      class << self
        attr_accessor :closes
      end

      def close = self.class.closes = self.class.closes.to_i + 1
    end
    child = Class.new(LittleGhost::Agent) do
      model "main"
      description "Child"
      system_prompt "Child"
      tools tool
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      agent_as_tool child
      subagents { raise "broken discovery" }
    end

    with_application(agent: parent) do |application|
      run = application.build_run(message: "hello")

      assert_raises(RuntimeError) { application.build_agent(run:, tools: [tool.new]) }
      assert_equal 2, tool.closes
      run.close
    end
  end

  def test_builder_closes_explicit_tools_when_model_resolution_fails
    tool = Class.new(LittleGhost::Tool) do
      tool_name "resource"
      description "Resource"
      attr_reader :closes

      def initialize(...)
        super
        @closes = 0
      end

      def close = @closes += 1
    end
    resource_tool = tool.new
    agent = Class.new(LittleGhost::Agent) do
      model { raise "model resolution failed" }
      system_prompt "Parent"
    end

    with_application(agent:) do |application|
      run = application.build_run(message: "hello")

      assert_raises(RuntimeError) { application.build_agent(run:, tools: [resource_tool]) }
      assert_equal 1, resource_tool.closes
      run.close
    end
  end

  def test_static_and_run_resolved_subagents_share_one_manager
    child = Class.new(LittleGhost::Agent) do
      model "main"
      description "Static child"
      system_prompt "Child"
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      subagent child, kind: "static"
      subagents do |_run|
        %w[static dynamic].map do |kind|
          LittleGhost::Subagents::Definition.new(
            kind:,
            description: "#{kind} child",
            factory: ->(_subagent_id) { raise "not invoked while building" }
          )
        end
      end
    end

    with_application(agent: parent) do |application|
      run = application.build_run(message: "hello")
      agent = application.build_agent(run:)
      spawn = agent.tool_registry.fetch("spawn_subagent")

      assert_equal %w[dynamic static], spawn.class.input_schema.dig("properties", "kind", "enum").sort
      assert_equal 1, agent.tool_registry.names.count("spawn_subagent")
      agent.close
      run.close
    end
  end

  private

  def assert_stubborn_producer_fails_run(interruption)
    provider = StubbornProvider.new

    with_application(provider:) do |application|
      payload = {message: "hello"}
      payload[:deadline_at] = Time.now + 0.05 if interruption == :deadline
      run = application.build_run(payload)
      events = []
      runner = Thread.new do
        run.each { |event| events << event }
      rescue => error
        error
      end
      runner.report_on_exception = false
      worker = provider.producer_started.pop

      run.cancellation_token.cancel if interruption == :cancellation
      provider.cleanup_started.pop

      assert runner.join(1), "run did not finish after its producer shutdown timeout"
      assert_instance_of LittleGhost::Support::InterruptibleStream::CleanupError, runner.value
      assert_same run.error, runner.value
      assert_instance_of LittleGhost::Support::InterruptibleStream::CleanupError, run.error
      assert run.failed?
      assert worker.alive?, "stubborn producer unexpectedly stopped before being released"
      terminal_events = events.filter_map do |event|
        event.type if %i[run_partial run_cancel run_stop run_error].include?(event.type)
      end
      assert_equal [:run_error], terminal_events
      assert events.last.data.fetch(:cleanup_failed)
    ensure
      provider.release << true if worker&.alive?
      worker&.join(1)
      runner&.kill
      runner&.join
    end
  end

  def progress_agent
    tool = LittleGhost::Tool.define(name: "continue_work", description: "Continue the test") { "continue" }
    Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Test"
      tools tool
    end
  end

  def with_application(
    agent: nil,
    session_store: nil,
    instrumentation: nil,
    settings: {},
    configure: nil,
    provider: ScriptedProvider.new
  )
    Dir.mktmpdir do |root|
      agent ||= Class.new(LittleGhost::Agent) do
        model "main"
        system_template "fixture/system"
      end
      prompt = File.join(root, "app/prompts/fixture/system.erb")
      config = File.join(root, "config/application.rb")
      FileUtils.mkdir_p(File.dirname(prompt))
      FileUtils.mkdir_p(File.dirname(config))
      File.write(prompt, "Prompt for <%= invocation.message.text %>")
      File.write(config, "# application fixture\n")
      application_class = Class.new(LittleGhost::Application)
      application_class.agent agent
      application_class.models models_for(provider, settings:)
      application_class.session_store session_store if session_store
      application_class.instrumentation instrumentation if instrumentation
      configure&.call(application_class)
      application = application_class.boot!(root:)
      yield application, provider, root
    end
  end

  def models_for(provider, settings: {})
    LittleGhost::ModelRegistry.new
      .provider(:test) { |**| provider }
      .profile("main", provider: :test, model: "test", settings:)
  end
end
