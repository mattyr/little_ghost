# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "test_helper"
require "little_ghost/ag_ui"

class ConfigurationTest < Minitest::Test
  def test_code_mode_configuration_is_explicit_and_frozen
    configuration = LittleGhost::Configuration.new

    configuration.code_mode = {engine: :ruby, sandbox: :native, limits: {programs: 4}}

    assert_equal :ruby, configuration.code_mode.fetch(:engine)
    assert_predicate configuration.code_mode, :frozen?
    assert_raises(ArgumentError) { configuration.code_mode = :ruby }
  end

  class SharedRuntimeResolver < LittleGhost::ModelResolver
    class << self
      attr_accessor :provider
    end

    def initialize(**)
    end

    def default_model = "default"

    def resolve(*)
      LittleGhost::Model.new(provider: self.class.provider, target: "test:model")
    end
  end

  class SharedRuntimeAgent < LittleGhost::Agent
    system_prompt "Answer clearly."
  end

  def test_configuration_builds_its_shared_runtime_once_across_threads
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:)

      runtimes = 10.times.map { Thread.new { configuration.runtime } }.map(&:value)

      assert_equal 1, runtimes.map(&:object_id).uniq.length
      assert_same configuration.runtime, runtimes.first
    end
  end

  def test_execution_scoped_configurations_have_independent_shared_runtimes
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        first = LittleGhost::Configuration.new(root: first_root)
        second = LittleGhost::Configuration.new(root: second_root)

        first_runtime = LittleGhost.with_configuration(first) { LittleGhost.runtime }
        second_runtime = LittleGhost.with_configuration(second) { LittleGhost.runtime }

        assert_same first.runtime, first_runtime
        assert_same second.runtime, second_runtime
        refute_same first_runtime, second_runtime
      end
    end
  end

  def test_standalone_calls_share_the_runtime_but_not_run_resources
    Dir.mktmpdir do |root|
      SharedRuntimeResolver.provider = ScriptedProvider.new
      configuration = LittleGhost::Configuration.new(root:)
      configuration.model_resolver = SharedRuntimeResolver

      first, second = LittleGhost.with_configuration(configuration) do
        [SharedRuntimeAgent.ask("first"), SharedRuntimeAgent.ask("second")]
      end

      assert_same first.runtime, second.runtime
      assert_same configuration.runtime, first.runtime
      refute_same first, second
      refute_same first.workspace, second.workspace
      refute_same first.sandbox, second.sandbox
    ensure
      SharedRuntimeResolver.provider = nil
    end
  end

  def test_shared_runtime_locks_configuration_after_successful_startup
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:)
      application_paths = ["application/prompts"]
      configuration.prompt_paths = application_paths
      configuration.runtime

      error = assert_raises(LittleGhost::ConfigurationError) do
        configuration.default_model :changed
      end
      assert_includes error.message, "configure the application before its first Agent or Assembly call"
      assert_raises(LittleGhost::ConfigurationError) do
        configuration.configure { |config| config.service_name "changed" }
      end
      assert_raises(LittleGhost::ConfigurationError) { configuration.providers(:invalid) }
      assert_raises(FrozenError) { configuration.prompt_paths << "other/prompts" }
      refute application_paths.frozen?
      application_paths << "application/overrides"
    end
  end

  def test_shared_runtime_owns_a_snapshot_of_nested_model_declarations
    Dir.mktmpdir do |root|
      models = {
        customer_support: {
          target: "test:model",
          settings: {temperature: 0.1}
        }
      }
      configuration = LittleGhost::Configuration.new(root:)
      configuration.providers = {test: {adapter: :test}}
      configuration.provider_adapter(:test, ->(**) { ScriptedProvider.new })
      configuration.models = models
      configuration.default_model = :customer_support

      runtime = configuration.runtime
      models[:customer_support][:settings][:temperature] = 0.9

      assert_equal 0.1, runtime.model_resolver.resolve(:customer_support).settings.fetch(:temperature)
    end
  end

  def test_shared_runtime_allows_its_configuration_file_to_finish_loading
    Dir.mktmpdir do |root|
      path = File.join(root, "config/little_ghost.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        LittleGhost.configure { |config| config.service_name "loaded-from-file" }
        LittleGhost.configuration.prompt_paths << "file/prompts"
      RUBY

      configuration = LittleGhost::Configuration.new(root:)

      assert_equal "loaded-from-file", configuration.runtime.service_name
      assert_includes configuration.prompt_paths, "file/prompts"
    end
  end

  def test_shared_runtime_hides_mutable_configuration_while_its_file_loads
    Dir.mktmpdir do |root|
      started = Queue.new
      release = Queue.new
      config_path = File.join(root, "config/little_ghost.rb")
      FileUtils.mkdir_p(File.dirname(config_path))
      File.write(config_path, "# loaded by the test override\n")
      configuration = LittleGhost::Configuration.new(root:)
      configuration.define_singleton_method(:load_configuration_file) do |_path|
        editable_values = copy_configuration_value(@configuration_values)
        @lifecycle_monitor.synchronize do
          @configuration_values = editable_values
          @configuration_file_loading = true
        end
        started << true
        release.pop
        prompt_paths << "file/prompts"
      ensure
        sealed_values = freeze_configuration_copy(@configuration_values)
        @lifecycle_monitor.synchronize do
          @configuration_values = sealed_values
          @configuration_file_loading = false
        end
      end

      worker = Thread.new { configuration.runtime }
      Timeout.timeout(1) { started.pop }

      assert_raises(LittleGhost::ConfigurationError) do
        configuration.prompt_paths << "late/prompts"
      end

      release << true
      runtime = Timeout.timeout(2) { worker.value }
      runtime_paths = runtime.prompt_paths.to_a.map { |entry| entry.path.to_s }
      assert_includes configuration.prompt_paths, "file/prompts"
      assert runtime_paths.any? { |path| path.end_with?("/file/prompts") }
      refute runtime_paths.any? { |path| path.end_with?("/late/prompts") }
    ensure
      release << true if release
      worker&.join(1)
    end
  end

  def test_shared_runtime_owns_scalar_configuration_strings
    Dir.mktmpdir do |root|
      service_name = +"support"
      default_model = +"first"
      skill_resource_root = +"workspace://skills"
      configuration = LittleGhost::Configuration.new(root:, service_name:)
      configuration.default_model = default_model
      configuration.skill_resource_root = skill_resource_root

      resolver = configuration.model_resolver
      runtime = configuration.runtime
      service_name.replace("changed")
      default_model.replace("second")
      skill_resource_root.replace("other/skills")

      assert_equal "support", configuration.service_name
      assert_equal "support", runtime.service_name
      assert_equal "first", configuration.default_model
      assert_same resolver, runtime.model_resolver
      assert_equal "first", runtime.model_resolver.default_model
      assert_equal "workspace://skills", configuration.skill_resource_root
      assert_equal "workspace://skills", runtime.skill_resource_root.to_s
      assert_raises(FrozenError) { configuration.service_name.replace("during") }
    end
  end

  def test_skill_resource_root_is_validated_when_configured
    configuration = LittleGhost::Configuration.new

    error = assert_raises(ArgumentError) do
      configuration.skill_resource_root = "relative/skills"
    end

    assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
    assert_nil configuration.skill_resource_root
  end

  def test_skill_resource_root_is_validated_during_construction
    error = assert_raises(ArgumentError) do
      LittleGhost::Configuration.new(skill_resource_root: "relative/skills")
    end

    assert_equal "resource_root must be an absolute path or workspace:// reference", error.message
  end

  def test_shared_runtime_rejects_configuration_changes_from_startup_callbacks
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:, service_name: "before")
      retained_paths = configuration.prompt_paths
      errors = []
      subscriber = TestInstrumentationSubscriber.new do |phase, name, _attributes|
        next unless phase == :start && name == :runtime

        begin
          configuration.service_name "during"
        rescue => error
          errors << error
        end
        begin
          configuration.prompt_paths << "late/prompts"
        rescue => error
          errors << error
        end
        retained_paths << "retained/prompts"
      end
      configuration.instrument(subscriber)

      runtime = configuration.runtime

      assert_equal "before", runtime.service_name
      assert_equal "before", configuration.service_name
      assert_instance_of LittleGhost::ConfigurationError, errors.fetch(0)
      assert_instance_of FrozenError, errors.fetch(1)
      refute_includes configuration.prompt_paths, "late/prompts"
      refute_includes runtime.prompt_paths.to_a.map(&:to_s), "late/prompts"
      refute_includes configuration.prompt_paths, "retained/prompts"
      refute_includes runtime.prompt_paths.to_a.map(&:to_s), "retained/prompts"
    end
  end

  def test_shared_runtime_does_not_hold_its_lifecycle_lock_during_callbacks
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:)
      errors = Queue.new
      subscriber = TestInstrumentationSubscriber.new do |phase, name, _attributes|
        next unless phase == :start && name == :runtime

        worker = Thread.new do
          configuration.service_name "during"
        rescue => error
          errors << error
        end
        raise "configuration worker did not finish" unless worker.join(1)
      end
      configuration.instrument(subscriber)

      configuration.runtime

      assert_instance_of LittleGhost::ConfigurationError, errors.pop
    end
  end

  def test_shared_runtime_validates_sealed_declarations_before_startup
    Dir.mktmpdir do |root|
      constructions = 0
      store = Class.new(LittleGhost::SessionStore) do
        define_method(:initialize) { |**| constructions += 1 }
      end
      cyclic = {}
      cyclic[:self] = cyclic
      configuration = LittleGhost::Configuration.new(root:)
      configuration.session_store = {provider: store, options: cyclic}

      assert_raises(ArgumentError) { configuration.runtime }
      assert_equal 0, constructions

      configuration.session_store = {provider: store}
      assert_instance_of store, configuration.runtime.session_store
      assert_equal 1, constructions
    end
  end

  def test_shared_runtime_preserves_application_keyed_hashes_as_collaborators
    Dir.mktmpdir do |root|
      key = Class.new do
        attr_accessor :armed

        def hash
          raise "application hash callback ran" if armed

          1
        end
      end.new
      configuration = LittleGhost::Configuration.new(root:)
      values = {key => "value"}
      key.armed = true
      configuration[:custom] = values

      runtime = configuration.runtime

      assert_same values, configuration[:custom]
      assert_same values, runtime.settings[:custom]
      refute_predicate values, :frozen?
    end
  end

  def test_failed_shared_runtime_startup_leaves_configuration_editable
    Dir.mktmpdir do |root|
      agent = File.join(root, "app/agents/conflict.rb")
      tool = File.join(root, "app/tools/conflict.rb")
      FileUtils.mkdir_p(File.dirname(agent))
      FileUtils.mkdir_p(File.dirname(tool))
      File.write(agent, "class RuntimeConflict; end")
      File.write(tool, "class RuntimeConflict; end")
      configuration = LittleGhost::Configuration.new(root:)

      assert_raises(LittleGhost::Support::Loader::ConflictError) { configuration.runtime }

      assert_equal "recovered", configuration.service_name("recovered")
    end
  end

  def test_explicit_runtime_remains_an_independent_configuration_snapshot
    Dir.mktmpdir do |root|
      configuration = LittleGhost::Configuration.new(root:)

      runtime = LittleGhost::Runtime.new(configuration: configuration)
      configuration.service_name "changed-later"

      assert_nil runtime.settings[:service_name]
      assert_equal "changed-later", configuration.service_name
    end
  end

  def test_event_logging_can_be_sent_to_stdout_without_duplicate_runtime_subscriptions
    stdout, stderr = capture_io do
      Dir.mktmpdir do |root|
        configuration = LittleGhost::Configuration.new(root:)
        configuration.log_events_to :stdout

        2.times { LittleGhost::Runtime.new(configuration:) }
      end
    end

    events = stdout.lines.map { |line| JSON.parse(line) }
    assert_empty stderr
    assert_equal 4, events.length
    assert events.all? { |event| event.fetch("name") == "little_ghost.runtime.startup" }
    assert events.all? { |event| event.fetch("level") == "info" }
    assert_equal %w[starting ready starting ready], events.map { |event| event.dig("payload", "status") }
  end

  def test_event_logging_can_be_sent_to_stderr_or_disabled
    configuration = nil
    stdout, stderr = capture_io do
      configuration = LittleGhost::Configuration.new
      assert_equal :stderr, configuration.log_events_to(:stderr)
      LittleGhost::Events.warn("provider.retry")
      assert_nil configuration.log_events_to(nil)
      LittleGhost::Events.warn("provider.retry")
    end

    assert_empty stdout
    assert_equal 1, stderr.lines.length
    assert_equal "provider.retry", JSON.parse(stderr).fetch("name")
    assert_nil configuration.log_events_to
  end

  def test_the_most_recent_configuration_replaces_the_process_console_destination
    first = LittleGhost::Configuration.new
    second = LittleGhost::Configuration.new
    stdout, stderr = capture_io do
      first.log_events_to :stdout
      second.log_events_to :stderr
      LittleGhost::Events.info("agent.ready")
      first.log_events_to nil
      LittleGhost::Events.info("agent.silent")
    end

    assert_empty stdout
    assert_equal ["agent.ready"], stderr.lines.map { |line| JSON.parse(line).fetch("name") }
    assert_nil first.log_events_to
    assert_nil second.log_events_to
  end

  def test_concurrent_configuration_replacement_leaves_one_console_destination
    stdout, stderr = capture_io do
      threads = 20.times.map do |index|
        Thread.new do
          LittleGhost::Configuration.new.log_events_to(index.even? ? :stdout : :stderr)
        end
      end
      threads.each(&:join)
      LittleGhost::Events.info("agent.ready")
    end

    events = (stdout.lines + stderr.lines).map { |line| JSON.parse(line) }
    assert_equal ["agent.ready"], events.map { |event| event.fetch("name") }
  end

  def test_lazily_loaded_console_configuration_receives_the_complete_startup_sequence
    stdout, stderr = capture_io do
      Dir.mktmpdir do |root|
        config = File.join(root, "config/little_ghost.rb")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, "LittleGhost.configure { |configuration| configuration.log_events_to :stdout }\n")

        LittleGhost::Runtime.new(configuration: LittleGhost::Configuration.new(root:))
      end
    end

    assert_empty stderr
    events = stdout.lines.map { |line| JSON.parse(line) }
    assert_equal %w[starting ready], events.map { |event| event.dig("payload", "status") }
  end

  def test_lazily_loaded_console_configuration_receives_a_paired_failure_sequence
    stdout, stderr = capture_io do
      Dir.mktmpdir do |root|
        config = File.join(root, "config/little_ghost.rb")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, <<~RUBY)
          LittleGhost.configure { |configuration| configuration.log_events_to :stdout }
          raise "invalid configuration"
        RUBY

        assert_raises(RuntimeError) do
          LittleGhost::Runtime.new(configuration: LittleGhost::Configuration.new(root:))
        end
      end
    end

    assert_empty stderr
    events = stdout.lines.map { |line| JSON.parse(line) }
    assert_equal %w[starting failed], events.map { |event| event.dig("payload", "status") }
    assert_equal %w[info error], events.map { |event| event.fetch("level") }
  end

  def test_event_logging_rejects_unknown_destinations
    error = assert_raises(ArgumentError) do
      LittleGhost::Configuration.new.log_events_to(:console)
    end

    assert_equal "event log destination must be :stdout, :stderr, or nil", error.message
  end

  def test_configuration_overrides_are_isolated_between_fibers
    configurations = [LittleGhost::Configuration.new, LittleGhost::Configuration.new]
    observed = []
    fibers = configurations.map do |configuration|
      Fiber.new do
        LittleGhost.with_configuration(configuration) do
          Fiber.yield
          observed << LittleGhost.configuration
        end
      end
    end

    fibers.each(&:resume)
    fibers.each(&:resume)

    assert_equal configurations, observed
  end

  class EntrypointWorkflow < LittleGhost::Workflow
    class << self
      attr_accessor :agent_class
    end

    private

    def perform
      invoke(self.class.agent_class)
    end
  end

  class ScriptedProvider < LittleGhost::Providers::Base
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

  class ProgressThenDeadlineProvider < LittleGhost::Providers::Base
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

  class ProgressThenRetryDeadlineProvider < LittleGhost::Providers::Base
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

  class FailingProvider < LittleGhost::Providers::Base
    def initialize(error)
      @error = error
    end

    def stream(_request)
      raise @error
    end
  end

  class StubbornProvider < LittleGhost::Providers::Base
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

  class ReasoningThenAnswerProvider < LittleGhost::Providers::Base
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

  def test_configuration_instances_do_not_share_declarations
    first = LittleGhost::Configuration.new
    second = LittleGhost::Configuration.new

    first.service_name "FirstAgent"
    second.service_name "SecondAgent"

    assert_equal "FirstAgent", first.service_name
    assert_equal "SecondAgent", second.service_name
    refute_same first, second
  end

  def test_configuration_files_apply_to_the_configuration_instance_loading_them
    Dir.mktmpdir do |first_root|
      Dir.mktmpdir do |second_root|
        [
          [first_root, "FirstAgent"],
          [second_root, "SecondAgent"]
        ].each do |root, agent|
          FileUtils.mkdir_p(File.join(root, "config"))
          File.write(
            File.join(root, "config/little_ghost.rb"),
            "LittleGhost.configure { |config| config.service_name #{agent.inspect} }\n"
          )
        end

        first = LittleGhost::Configuration.new
        second = LittleGhost::Configuration.new
        first.root first_root
        second.root second_root

        first.load_file!
        second.load_file!

        assert_equal "FirstAgent", first.service_name
        assert_equal "SecondAgent", second.service_name
      end
    end
  end

  def test_minimal_application_resolves_root_agent_prompt_and_model
    with_runtime do |harness, provider, root|
      run = harness.agent_instance.call(message: "Build it")

      assert run.completed?
      assert_equal "Done", run.response
      assert_equal Pathname.new(File.realpath(root)), harness.root
      assert_equal "Prompt for Build it", provider.requests.first.messages.first.text
      assert_same harness.runtime_instance, run.runtime
    end
  end

  def test_shared_runtime_serves_independent_calls_concurrently
    provider = Class.new(LittleGhost::Providers::Base) do
      attr_reader :ready, :release

      def initialize
        @ready = Queue.new
        @release = Queue.new
      end

      def stream(request)
        ready << true
        release.pop
        text = "Done: #{request.messages.last.text}"
        response = LittleGhost::ModelResponse.new(
          message: LittleGhost::Message.new(role: :assistant, content: text),
          stop_reason: :end_turn,
          usage: LittleGhost::Usage.new(input_tokens: 1, output_tokens: 1)
        )
        [
          LittleGhost::StreamEvent.build(:message_start),
          LittleGhost::StreamEvent.build(:text_delta, text:),
          LittleGhost::StreamEvent.build(:message_stop, response:),
          LittleGhost::StreamEvent.build(:usage, usage: response.usage)
        ].each
      end
    end.new

    with_runtime(provider:) do |harness|
      callers = %w[first second].map do |message|
        Thread.new { harness.agent_instance.ask(message) }
      end

      2.times do
        assert provider.ready.pop(timeout: 1), "shared Runtime did not start an independent call"
      end
      2.times { provider.release << true }
      callers.each do |thread|
        assert thread.join(1), "shared Runtime call did not finish"
      end
      runs = callers.map(&:value)

      assert_equal ["Done: first", "Done: second"], runs.map(&:response).sort
      assert runs.all?(&:completed?)
      refute_same runs.fetch(0), runs.fetch(1)
      refute_same runs.fetch(0).workspace, runs.fetch(1).workspace
      refute_same runs.fetch(0).sandbox, runs.fetch(1).sandbox
    ensure
      2.times { provider.release << true }
      callers&.each { |thread| thread.join(1) }
      callers&.each(&:kill)
    end
  end

  def test_stream_is_generic_and_call_returns_the_run
    with_runtime do |harness|
      events = harness.agent_instance.stream({message: "Build it"}).to_a

      assert_equal :run_start, events.first.type
      assert_equal :run_stop, events.last.type
      assert_includes events.map(&:type), :text_delta
      assert events.all? { |event| event.is_a?(LittleGhost::StreamEvent) }
    end
  end

  def test_partial_run_uses_the_latest_assistant_message_instead_of_concatenating_progress
    agent = progress_agent

    with_runtime(agent:, provider: ProgressThenDeadlineProvider.new) do |harness|
      run = harness.agent_instance.call(message: "Build it", session_id: "conversation")

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

      with_runtime(agent: progress_agent, provider:) do |harness|
        run = harness.agent_instance.call(message: "Build it", session_id: "conversation")

        assert run.partial?
        assert_equal "Stable progress", run.response
        refute_includes run.response, "Discarded"
      end
    end
  end

  def test_cancelled_run_checkpoints_completed_turns
    provider = ProgressThenDeadlineProvider.new(LittleGhost::CancelledError.new("cancelled"))

    with_runtime(agent: progress_agent, provider:) do |harness|
      run = harness.agent_instance.call(message: "Build it", session_id: "conversation")

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

    with_runtime(agent: progress_agent, provider:) do |harness|
      run = harness.agent_instance.call(message: "Build it", session_id: "conversation")

      assert run.failed?
      assert_equal 5, run.usage.total_tokens
      assert_equal %i[user assistant tool assistant tool], run.session.history.map(&:role)
      assert_equal "Progress 2", run.session.history.fetch(3).text
    end
  end

  def test_run_interject_forwards_to_active_entrypoint_and_rejects_terminal_states
    provider = Class.new(LittleGhost::Providers::Base).new
    started = Queue.new
    release = Queue.new
    interjection_started = Queue.new
    release_interjection = Queue.new
    requests = []
    response = lambda do |text|
      LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: text),
        stop_reason: :end_turn
      )
    end
    provider.define_singleton_method(:stream) do |request|
      requests << request
      if requests.length == 1
        started << true
        release.pop
        value = response.call("would finish")
      else
        interjection_started << true
        release_interjection.pop
        value = response.call("steered")
      end
      [LittleGhost::StreamEvent.build(:message_stop, response: value)].each
    end
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Test"
    end

    with_runtime(agent:, provider:) do |harness|
      run = harness.agent_instance.build_run(message: "work")
      not_ready = assert_raises(LittleGhost::AgentInterjectionError) do
        run.interject("too early")
      end
      assert_equal "Run entrypoint is not ready for interjections", not_ready.message

      runner = Thread.new { run.call }
      started.pop
      interjected = Thread.new do
        run.interject(
          "steer",
          interjection_id: "slack-1",
          batch_key: "channel",
          metadata: {authority: "signed"}
        )
      end
      release << true
      interjection_started.pop

      assert_predicate runner, :alive?

      release_interjection << true
      assert_equal "steered", interjected.value.text
      assert_equal ["slack-1"], interjected.value.interjection_ids
      assert_equal "channel", interjected.value.batch_key
      assert runner.value.completed?

      terminal = assert_raises(LittleGhost::AgentInterjectionError) do
        run.interject("too late")
      end
      assert_equal "Run has already finished", terminal.message
    ensure
      release << true if runner&.alive?
      release_interjection << true if interjected&.alive?
      runner&.kill
      interjected&.kill
    end
  end

  def test_terminal_cleanup_waits_for_runtime_hook_interjection_preparation
    provider = Class.new(LittleGhost::Providers::Base).new
    model_started = Queue.new
    release_model = Queue.new
    preparation_started = Queue.new
    release_preparation = Queue.new
    resource_closed = Queue.new
    requests = []
    response = lambda do |text|
      LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content: text),
        stop_reason: :end_turn
      )
    end
    provider.define_singleton_method(:stream) do |request|
      requests << request
      if requests.one?
        model_started << true
        release_model.pop
      end
      value = response.call(requests.one? ? "would finish" : "steered")
      [LittleGhost::StreamEvent.build(:message_stop, response: value)].each
    end
    hook = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:prepare_run) do |run|
        run.register { resource_closed << true }
      end
      define_method(:prepare_interjection) do |_run, payload|
        preparation_started << true
        release_preparation.pop
        payload
      end
    end
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Test"
    end

    with_runtime(agent:, provider:, configure: ->(harness) { harness.runtime_hook hook }) do |harness|
      execution = harness.agent_instance.start_execution(message: "work")
      model_started.pop
      interjection = Thread.new do
        execution.interject(message: "steer")
      rescue => error
        error
      end
      preparation_started.pop
      release_model << true

      assert_raises(LittleGhost::DeadlineExceededError) do
        execution.wait(deadline: Time.now + 0.01)
      end
      assert resource_closed.empty?, "run resources closed while interjection preparation was active"

      release_preparation << true
      assert_instance_of LittleGhost::AgentInterjectionError, interjection.value
      assert execution.wait(deadline: Time.now + 1).completed?
      assert resource_closed.pop
    ensure
      release_model << true if execution&.active?
      release_preparation << true if interjection&.alive?
      interjection&.join
      execution&.close(deadline: Time.now + 1) if execution&.active?
    end
  end

  def test_abnormal_runs_report_cumulative_usage_once_end_to_end
    {
      LittleGhost::CancelledError.new("cancelled") => [:cancelled, :run_cancel],
      LittleGhost::ProviderError.new("offline") => [:failed, :run_error]
    }.each do |error, (expected_outcome, expected_terminal)|
      recorded = []
      instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
      instrumentation.subscribe(TestTelemetryRecorder.new(recorded))
      provider = ProgressThenDeadlineProvider.new(error)

      with_runtime(agent: progress_agent, provider:) do |harness|
        run = harness.agent_instance.build_run(message: "Build it", session_id: "conversation")
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
      with_runtime(provider: FailingProvider.new(error)) do |harness|
        terminal = harness.agent_instance.stream({message: "Build it"}).to_a.last

        assert_equal :run_error, terminal.type
        assert_equal expected, terminal.data.fetch(:message)
        refute_includes terminal.data.fetch(:message), "raw"
      end
    end
  end

  def test_deadline_is_propagated_to_the_model_request
    deadline = Time.now + 60
    with_runtime do |harness, provider|
      harness.agent_instance.call(message: "Build it", deadline_at: deadline)

      assert_equal deadline, provider.requests.first.deadline
    end
  end

  def test_framework_emits_correlated_semantic_telemetry_without_ui_deltas
    recorded = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))

    with_runtime do |harness|
      harness.agent_instance.call(message: "Build it")
    end

    names = recorded.map(&:first).reject { |name| name.to_s.start_with?("runtime_") }
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
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))

    with_runtime do |harness|
      harness.agent_instance.call(message: "Build it", session_id: "session-1")
    end

    run_start = recorded.assoc(:run_start).last
    run_stop = recorded.assoc(:run_stop).last
    assert_equal "session-1", run_start.fetch(:session_id)
    assert_equal "Build it", JSON.parse(run_start.fetch(:diagnostic_input))
    assert_equal "Done", JSON.parse(run_stop.fetch(:diagnostic_output))
  end

  def test_run_telemetry_never_captures_provider_reasoning_artifacts
    recorded = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))
    message = LittleGhost::Message.new(
      role: :assistant,
      content: LittleGhost::Content::Reasoning.new(
        signature: "provider-signature",
        details: [{"type" => "provider", "provider_state" => "continuity"}],
        text: "visible reasoning"
      )
    )

    with_runtime do |harness|
      harness.agent_instance.call(message:)
    end

    captured = JSON.parse(recorded.assoc(:run_start).last.fetch(:diagnostic_input))
    assert_equal "visible reasoning", captured.dig("content", 0, "text")
    refute_includes JSON.generate(captured), "provider-signature"
    refute_includes JSON.generate(captured), "continuity"
  end

  def test_model_failure_before_output_omits_time_to_first_token
    recorded = []
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))

    with_runtime(provider: FailingProvider.new(LittleGhost::ProviderError.new("offline"))) do |harness|
      harness.agent_instance.call(message: "Build it")
    end

    model_stop = recorded.assoc(:model_stop).last
    assert_equal :error, model_stop[:outcome]
    refute model_stop.key?(:time_to_first_token)
  end

  def test_application_is_host_neutral
    with_runtime do |harness|
      refute_respond_to harness, :hosted
      refute_respond_to harness.class, :rack_app
    end
  end

  def test_default_model_names_are_normalized_to_strings
    harness = TestHarness.new

    harness.default_model :support

    assert_equal "support", harness.default_model
  end

  def test_custom_model_resolver_cannot_be_combined_with_default_resolver_configuration
    resolver = Class.new(LittleGhost::ModelResolver)
    harness = TestHarness.new
    harness.model_resolver resolver
    harness.models(main: {target: "test:model"})
    harness.default_model :main

    error = assert_raises(LittleGhost::ConfigurationError) { harness.model_resolver }

    assert_equal "custom model_resolver cannot be combined with models, default_model", error.message
  end

  def test_instrument_dsl_subscribes_configured_objects
    events = []
    subscriber = TestTelemetryRecorder.new(events)

    with_runtime(configure: lambda { |harness|
      harness.service_name "support-agent"
      harness.instrument subscriber
    }) { nil }

    runtime_start = events.assoc(:runtime_start)
    assert_equal "support-agent", runtime_start.last.fetch(:service_name)
    assert events.assoc(:runtime_stop)
  end

  def test_application_uses_an_in_memory_session_store_by_default
    with_runtime do |harness|
      assert_instance_of LittleGhost::SessionStores::Memory, harness.runtime_instance.session_store
    end
  end

  def test_session_store_configuration_builds_the_declared_provider
    with_runtime(configure: ->(harness) { harness.session_store = {provider: LittleGhost::SessionStores::Memory} }) do |harness|
      assert_instance_of LittleGhost::SessionStores::Memory, harness.runtime_instance.session_store
    end
  end

  def test_runtime_hooks_prepare_runs_and_interjections_in_registration_order
    calls = []
    first = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:prepare_run) do |run|
        calls << [:run, :first, run]
        run
      end

      define_method(:prepare_interjection) do |run, payload|
        calls << [:interjection, :first, run, payload.fetch(:message)]
        payload.merge(first: true)
      end
    end
    second = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:prepare_run) do |run|
        calls << [:run, :second, run]
        run
      end

      define_method(:prepare_interjection) do |run, payload|
        calls << [:interjection, :second, run, payload.fetch(:first)]
        payload.merge(second: true)
      end
    end

    with_runtime(configure: lambda { |harness|
      harness.runtime_hook first
      harness.runtime_hook second
    }) do |harness|
      run = harness.agent_instance.build_run(message: "hello")

      assert_equal({message: "interject", first: true, second: true}, run.prepare_interjection(message: "interject"))
      assert_equal [
        [:run, :first, run],
        [:run, :second, run],
        [:interjection, :first, run, "interject"],
        [:interjection, :second, run, true]
      ], calls
    end
  end

  def test_runtime_error_hooks_take_precedence_over_default_error_messages
    hook = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:error_message) do |error, _run|
        "Handled: #{error.class}" if error.is_a?(RuntimeError)
      end
    end

    with_runtime(configure: ->(harness) { harness.runtime_hook hook }) do |harness|
      assert_equal "Handled: RuntimeError", harness.runtime_instance.error_message(RuntimeError.new, nil)
      assert_equal "I hit an error while generating a response. Please retry.",
        harness.runtime_instance.error_message(ArgumentError.new, nil)
    end
  end

  def test_runtime_history_hooks_select_and_normalize_session_history
    calls = []
    deferred = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:session_history) do |run, stored:, fallback:|
        calls << [run, stored, fallback]
        nil
      end
    end
    selected = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:session_history) do |_run, stored:, fallback:|
        [stored.first, {role: :user, content: fallback.first.text.upcase}]
      end
    end

    with_runtime(configure: lambda { |harness|
      harness.runtime_hook deferred
      harness.runtime_hook selected
    }) do |harness|
      runtime = harness.runtime_instance
      run = Object.new
      stored = [LittleGhost::Message.new(role: :assistant, content: "Earlier")]
      fallback = [LittleGhost::Message.new(role: :user, content: "continue")]
      session = Struct.new(:messages) do
        def history(fallback: []) = messages.empty? ? fallback : messages
      end.new(stored)

      history = runtime.session_history(run, session, fallback:)

      assert_equal [[run, stored, fallback]], calls
      assert_equal %i[assistant user], history.map(&:role)
      assert_equal ["Earlier", "CONTINUE"], history.map(&:text)
      assert history.frozen?
    end
  end

  def test_runtime_uses_the_session_default_when_history_hooks_defer
    hook = Class.new(LittleGhost::Runtime::Hook)

    with_runtime(configure: ->(harness) { harness.runtime_hook hook }) do |harness|
      fallback = [LittleGhost::Message.new(role: :user, content: "Start here")]
      session = Struct.new(:messages) do
        def history(fallback: []) = messages.empty? ? fallback : messages
      end.new([])

      assert_same fallback, harness.runtime_instance.session_history(Object.new, session, fallback:)
    end
  end

  def test_runtime_history_hook_reconciles_a_persisted_session_for_an_agent_run
    store = LittleGhost::SessionStores::Memory.new
    stored = LittleGhost::Message.new(role: :assistant, content: "Persisted answer")
    store.replace("conversation", actor_id: "actor", messages: [stored], state: {}, metadata: {})
    calls = []
    hook = Class.new(LittleGhost::Runtime::Hook) do
      define_method(:session_history) do |run, stored:, fallback:|
        calls << [run, stored, fallback]
        [stored.first, fallback.first]
      end
    end

    with_runtime(session_store: store, configure: ->(harness) { harness.runtime_hook hook }) do |harness, provider|
      supplied = LittleGhost::Message.new(role: :user, content: "Supplied context")
      run = harness.agent_instance.call(
        message: "Continue",
        history: [supplied],
        session_id: "conversation",
        actor_id: "actor"
      )

      assert_equal 1, calls.length
      assert_same run, calls.first.fetch(0)
      assert_equal [[:assistant, "Persisted answer"]], calls.first.fetch(1).map { |message| [message.role, message.text] }
      assert_equal [[:user, "Supplied context"]], calls.first.fetch(2).map { |message| [message.role, message.text] }
      request_texts = provider.requests.first.messages.map(&:text)
      assert_includes request_texts, "Persisted answer"
      assert_includes request_texts, "Supplied context"
      assert_includes request_texts, "Continue"
    end
  end

  def test_runtime_hook_configuration_requires_hook_classes
    error = assert_raises(ArgumentError) { TestHarness.new.runtime_hook Class.new }

    assert_equal "runtime_hook must be a LittleGhost::Runtime::Hook class", error.message
  end

  def test_session_actor_can_be_resolved_from_the_invocation
    store = LittleGhost::SessionStores::Memory.new

    with_runtime(
      session_store: store,
      configure: ->(harness) { harness.session_actor { |invocation| invocation.session_id } }
    ) do |harness|
      run = harness.agent_instance.call(message: "Continue", session_id: "conversation", actor_id: "principal")

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
    with_runtime(agent:) do |harness, provider|
      harness.agent_instance.call(message: "hello", channel: "slack")

      assert_equal "slack:hello", provider.requests.first.messages.first.text
    end
  end

  def test_custom_model_resolver_can_apply_invocation_profiles
    with_runtime(settings: {temperature: 0.1}) do |harness, provider|
      harness.agent_instance.call(
        message: "hello",
        model_configuration: {"profiles" => {"main" => {"settings" => {"temperature" => 0.7, "max_tokens" => 50}}}}
      )

      assert_equal({temperature: 0.7, max_tokens: 50}, provider.requests.first.settings)
    end
  end

  def test_grouped_tools_are_resolved_for_the_run
    static_tool = Class.new(LittleGhost::Tool) do
      tool_name "static"
      description "Static tool"
    end
    dynamic_tool = Class.new(LittleGhost::Tool) do
      tool_name "dynamic"
      description "Dynamic tool"
    end
    provider = Class.new do
      def self.tools(binding)
        binding.run.invocation[:dynamic] ? [dynamic_tool] : []
      end

      class << self
        attr_accessor :dynamic_tool
      end
    end
    provider.dynamic_tool = dynamic_tool
    agent = Class.new(LittleGhost::Agent) do
      model "main"
      tools static_tool, provider
    end

    with_runtime(agent:) do |harness, provider|
      run = harness.agent_instance.build_run(message: "hello", dynamic: true)
      built_agent = harness.build_agent(run:, agent_path: "/root/dynamic_child")

      assert_equal %w[static dynamic], built_agent.tool_registry.names
      assert built_agent.tool_registry.all? { |tool| tool.run }
      assert_equal "/root/dynamic_child", built_agent.agent_path
    end
  end

  def test_workflow_entrypoint_marks_run_telemetry_without_changing_child_agent_telemetry
    recorded = []
    expected_agent_id = nil
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))

    with_runtime(
      configure: lambda do |configuration|
        EntrypointWorkflow.agent_class = configuration.agent_class
        expected_agent_id = configuration.agent_class.agent_id
      end
    ) do |harness|
      run = harness.runtime_instance.build_run(
        {message: "hello"},
        agent_class: EntrypointWorkflow.agent_class,
        entrypoint_class: EntrypointWorkflow
      )
      run.call
    end

    run_start = recorded.assoc(:run_start).last
    run_stop = recorded.assoc(:run_stop).last
    agent_start = recorded.assoc(:agent_start).last
    assert_equal :workflow, run_start.fetch(:entrypoint_kind)
    assert_equal "ConfigurationTest::EntrypointWorkflow", run_start.fetch(:workflow_name)
    refute run_start.key?(:agent_id)
    assert_equal "ConfigurationTest::EntrypointWorkflow", run_stop.fetch(:workflow_name)
    refute run_stop.key?(:agent_id)
    assert_equal expected_agent_id, agent_start.fetch(:agent_id)
    assert_equal run_start.fetch(:operation_id), agent_start.fetch(:parent_operation_id)
  ensure
    EntrypointWorkflow.agent_class = nil
  end

  def test_graph_has_the_same_standalone_interface_as_an_agent
    with_runtime do |harness|
      agent_class = harness.agent_class
      graph_class = Class.new(LittleGhost::Graph) do
        node :answer, agent_class
        start :answer
        finish :answer
      end

      run = graph_class.new(runtime: harness.runtime_instance).ask("hello")

      assert run.completed?
      assert_equal "Done", run.response
      assert_equal :graph, graph_class.assembly_kind
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

    with_runtime(agent:) { |harness| harness.agent_instance.call(message: "hello") }

    assert_equal 1, tool.closes
  end

  def test_run_closes_resources_before_emitting_its_terminal_event
    order = []

    with_runtime do |harness|
      run = harness.agent_instance.build_run(message: "hello")
      run.register { order << :closed }
      run.each do |event|
        order << :terminal if %i[run_partial run_cancel run_stop run_error].include?(event.type)
      end
    end

    assert_equal %i[closed terminal], order
  end

  def test_cleanup_failure_replaces_success_with_a_failed_terminal_event
    events = []

    with_runtime do |harness|
      run = harness.agent_instance.build_run(message: "hello")
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
    with_runtime do |harness|
      harness.runtime_instance.define_singleton_method(:error_message) { |_error, _run| raise "formatter failed" }
      run = harness.agent_instance.build_run(message: "hello")
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

    with_runtime(provider: FailingProvider.new(cleanup_error)) do |harness|
      run = harness.agent_instance.build_run(message: "hello")

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
    subscriber = Class.new(LittleGhost::Instrumentation::Subscriber) do
      def finish(name, _attributes)
        raise "run stop instrumentation failed" if name == :run
      end
    end
    LittleGhost::Instrumentation.subscribe(subscriber.new)

    with_runtime(provider: FailingProvider.new(cleanup_error)) do |harness|
      run = harness.agent_instance.build_run(message: "hello")

      raised = assert_raises(LittleGhost::CleanupError) { run.call }

      assert_same cleanup_error, raised
      assert_same cleanup_error, run.error
    end
  end

  def test_run_close_prioritizes_cleanup_errors
    ordinary_error = RuntimeError.new("ordinary close failure")
    cleanup_error = LittleGhost::CleanupError.new("resource is still running")

    with_runtime do |harness|
      run = harness.agent_instance.build_run(message: "hello")
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
    closes = 0
    tool_class = Class.new(LittleGhost::Tool) do
      tool_name "shared"
      description "Shared tool"

      define_method(:close) { closes += 1 }
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

    with_runtime(agent: parent) { |harness| harness.agent_instance.call(message: "hello") }

    assert_equal 2, closes
  end

  def test_run_owns_an_agent_tool_child_when_its_wrapper_name_collides
    closes = 0
    collision = LittleGhost::Tool.define(name: "delegate", description: "Existing tool") { "existing" }
    child = Class.new(LittleGhost::Agent) do
      agent_id "delegate"
      model "main"
      description "Child"
      system_prompt "Child"

      define_method(:close) do
        closes += 1
        super
      end
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      tools collision
      agent_as_tool child
    end

    with_runtime(agent: parent) { |harness| harness.agent_instance.call(message: "hello") }

    assert_equal 1, closes
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

    with_runtime(session_store: store) do |harness, provider|
      harness.agent_instance.call(message: "Continue", session_id: "conversation", actor_id: "actor")

      assert_includes provider.requests.first.messages.map(&:text), "Earlier"
      assert_includes store.load("conversation", actor_id: "actor").fetch(:messages).map(&:text), "Done"
    end
  end

  def test_model_reasoning_survives_same_run_continuation_but_not_the_session_checkpoint
    store = LittleGhost::SessionStores::Memory.new
    provider = ReasoningThenAnswerProvider.new

    with_runtime(agent: progress_agent, provider:, session_store: store) do |harness|
      run = harness.agent_instance.call(message: "Continue", session_id: "conversation", actor_id: "actor")

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

    with_runtime(session_store: store) do |harness, provider|
      harness.agent_instance.call(
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
    instrumentation = LittleGhost::Instrumentation.notifier = LittleGhost::Instrumentation::Bus.new(
      content_capture: LittleGhost::Support::ContentCapture.new(enabled: true)
    )
    instrumentation.subscribe(TestTelemetryRecorder.new(recorded))

    with_runtime(session_store: store) do |harness|
      run = harness.agent_instance.call(message: "Continue")

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
    with_runtime do |harness|
      replacement_provider = ScriptedProvider.new("Replacement")
      replacement_models = models_for(replacement_provider)
      isolated = harness.build(model_resolver: replacement_models)

      result = isolated.agent_instance.call(message: "hello")

      assert_equal "Replacement", result.response
      refute harness.settings.frozen?
      assert_same replacement_models, isolated.runtime_instance.model_resolver
      refute_same harness.runtime_instance.model_resolver, isolated.runtime_instance.model_resolver
    end
  end

  def test_build_can_override_external_services_before_the_application_boots
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/little_ghost.rb"), "# harness fixture\n")
      agent = Class.new(LittleGhost::Agent) do
        model "main"
        system_prompt "Test"
      end
      subscriber = TestInstrumentationSubscriber.new { raise "external instrumentation was published" }
      configuration = TestHarness.new
      configuration.root root
      configuration.select_agent agent
      configuration.instrument subscriber
      configuration.session_store = {
        provider: Class.new(LittleGhost::SessionStore) do
          def initialize(**) = raise("external sessions were initialized")
        end
      }

      harness = configuration.build(
        model_resolver: models_for(ScriptedProvider.new),
        session_store: {provider: LittleGhost::SessionStores::Memory},
        instrumentation_subscribers: []
      )

      assert_instance_of LittleGhost::SessionStores::Memory, harness.runtime_instance.session_store
      refute configuration.instance_variable_defined?(:@booted_application)
    end
  end

  def test_runtime_consumes_configuration_settings
    Dir.mktmpdir do |root|
      agent_path = File.join(root, "app/agents/probe_agent.rb")
      FileUtils.mkdir_p(File.dirname(agent_path))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/little_ghost.rb"), "# harness fixture\n")
      File.write(agent_path, "class ProbeAgent < LittleGhost::Agent; end\n")
      configuration = TestHarness.new
      configuration.root root
      configuration.select_agent "ProbeAgent"

      runtime = LittleGhost::Runtime.new(configuration: configuration)

      assert_equal File.realpath(root), runtime.root.to_s
      assert_equal File.realpath(root), runtime.loader.root
    end
  end

  def test_build_creates_a_loader_for_an_overridden_root
    with_runtime do |harness|
      Dir.mktmpdir do |other_root|
        FileUtils.mkdir_p(File.join(other_root, "config"))
        File.write(File.join(other_root, "config/little_ghost.rb"), "# alternate harness\n")

        isolated = harness.build(root: other_root)

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

    with_runtime(agent: parent) do |harness|
      run = harness.agent_instance.build_run(message: "hello")

      assert_raises(RuntimeError) { harness.build_agent(run:, tools: [tool.new]) }
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

    with_runtime(agent:) do |harness|
      run = harness.agent_instance.build_run(message: "hello")

      assert_raises(RuntimeError) { harness.build_agent(run:, tools: [resource_tool]) }
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

    with_runtime(agent: parent) do |harness|
      run = harness.agent_instance.build_run(message: "hello")
      agent = harness.build_agent(run:)
      spawn = agent.tool_registry.fetch("spawn_subagent")

      assert_equal %w[dynamic static], spawn.class.input_schema.dig("properties", "kind", "enum").sort
      assert_equal 1, agent.tool_registry.names.count("spawn_subagent")
      agent.close
      run.close
    end
  end

  def test_static_subagent_can_spawn_with_declared_tools
    delegated_tool = Class.new(LittleGhost::Tool) do
      tool_name "inspect_source"
      description "Inspect source"

      def call(_input) = "source"
    end
    child = Class.new(LittleGhost::Agent) do
      model "main"
      description "Static child"
      system_prompt "Child"
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      subagent child, kind: "static", tools: [delegated_tool]
    end

    with_runtime(agent: parent) do |harness, provider|
      run = harness.agent_instance.build_run(message: "hello")
      agent = harness.build_agent(run:)
      result = agent.tool_registry.fetch("spawn_subagent").execute({
        "kind" => "static", "task_name" => "inspect_source", "task" => "inspect", "mode" => "sync"
      })

      assert result.success?
      assert_equal "finished", JSON.parse(result.content).fetch("status")
      assert_includes provider.requests.fetch(0).tools.map { |tool| tool.fetch(:name) }, "inspect_source"
    ensure
      agent&.close
      run&.close
    end
  end

  def test_builder_binds_canonical_path_and_relays_delegated_activity
    child = Class.new(LittleGhost::Agent) do
      model "main"
      description "Child"
      system_prompt "Child"
      before_invocation do
        delegation_activity.publish
      end
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      subagent child, kind: "child"
    end
    parent_turn = 0
    provider = Class.new(LittleGhost::Providers::Base).new
    provider.define_singleton_method(:stream) do |request|
      system = request.messages.find { |message| message.role == :system }&.text
      parent_turn += 1 if system == "Parent"
      content, stop_reason = if system == "Parent" && parent_turn == 1
        [
          LittleGhost::Content::ToolUse.new(
            id: "spawn-1",
            name: "spawn_subagent",
            input: {
              "kind" => "child",
              "task_name" => "inspect_activity",
              "task" => "inspect",
              "mode" => "sync"
            }
          ),
          :tool_use
        ]
      else
        ["done", :end_turn]
      end
      response = LittleGhost::ModelResponse.new(
        message: LittleGhost::Message.new(role: :assistant, content:),
        stop_reason:,
        usage: LittleGhost::Usage.new
      )
      [LittleGhost::StreamEvent.build(:message_stop, response:)].each
    end

    with_runtime(agent: parent, provider:) do |harness|
      run = harness.agent_instance.build_run(message: "start")
      events = []
      run.each { |event| events << event }
      activity = events.filter_map do |event|
        event.data[:event] if event.type == :subagent && event.data.dig(:event, :event) == "activity"
      end

      assert run.completed?
      assert activity.any? { |event| event[:subagent_id] == "/root/inspect_activity" }
    end
  end

  def test_application_restores_nested_async_subagent_conversations
    provider = Class.new(LittleGhost::Providers::Base).new
    counts = Hash.new(0)
    tool_id = 0
    child_id = nil
    grandchild_id = nil
    provider.define_singleton_method(:stream) do |request|
      system = request.messages.find { |message| message.role == :system }&.text
      counts[system] += 1
      count = counts.fetch(system)
      latest_result = request.messages.reverse_each.lazy.flat_map do |message|
        message.content.grep(LittleGhost::Content::ToolResult)
      end.first
      parsed = latest_result && JSON.parse(latest_result.content)
      name, input, text = case [system, count]
      when ["Parent", 1]
        [
          "spawn_subagent",
          {"kind" => "child", "task_name" => "investigate", "task" => "investigate", "mode" => "async"},
          nil
        ]
      when ["Parent", 2]
        child_id = parsed.dig("subagent", "subagent_id")
        ["wait_for_subagents", {"subagent_ids" => [child_id]}, nil]
      when ["Parent", 4]
        ["send_message_to_subagent", {"subagent_id" => child_id, "message" => "continue", "mode" => "sync"}, nil]
      when ["Child", 1]
        [
          "spawn_subagent",
          {"kind" => "grandchild", "task_name" => "inspect", "task" => "inspect", "mode" => "async"},
          nil
        ]
      when ["Child", 2]
        grandchild_id = parsed.dig("subagent", "subagent_id")
        ["wait_for_subagents", {"subagent_ids" => [grandchild_id]}, nil]
      when ["Child", 4]
        ["send_message_to_subagent", {
          "subagent_id" => grandchild_id,
          "message" => "continue",
          "mode" => "sync"
        }, nil]
      else
        [nil, nil, "#{system} complete"]
      end
      message = if name
        tool_id += 1
        LittleGhost::Message.new(
          role: :assistant,
          content: LittleGhost::Content::ToolUse.new(id: "tool-#{tool_id}", name:, input:)
        )
      else
        LittleGhost::Message.new(role: :assistant, content: text)
      end
      response = LittleGhost::ModelResponse.new(
        message:,
        stop_reason: name ? :tool_use : :end_turn,
        usage: LittleGhost::Usage.new
      )
      [LittleGhost::StreamEvent.build(:message_stop, response:)].each
    end
    grandchild = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Grandchild"
      description "Grandchild"
    end
    child = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Child"
      description "Child"
      subagent grandchild, kind: "grandchild"
    end
    parent = Class.new(LittleGhost::Agent) do
      model "main"
      system_prompt "Parent"
      subagent child, kind: "child"
    end
    store = LittleGhost::SessionStores::Memory.new

    with_runtime(agent: parent, provider:, session_store: store) do |harness|
      first = harness.agent_instance.call(message: "start", session_id: "durable-nested")
      second = harness.agent_instance.call(message: "resume", session_id: "durable-nested")

      assert first.completed?
      assert second.completed?
      assert_equal "/root/investigate", child_id
      assert_equal "/root/investigate/inspect", grandchild_id
      assert_equal 2, counts.fetch("Grandchild")
    end
  end

  private

  def assert_stubborn_producer_fails_run(interjection)
    provider = StubbornProvider.new

    with_runtime(provider:) do |harness|
      payload = {message: "hello"}
      payload[:deadline_at] = Time.now + 0.05 if interjection == :deadline
      run = harness.agent_instance.build_run(payload)
      events = []
      runner = Thread.new do
        run.each { |event| events << event }
      rescue => error
        error
      end
      runner.report_on_exception = false
      worker = provider.producer_started.pop

      run.cancellation_token.cancel if interjection == :cancellation
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

  def with_runtime(
    agent: nil,
    session_store: nil,
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
      config = File.join(root, "config/little_ghost.rb")
      FileUtils.mkdir_p(File.dirname(prompt))
      FileUtils.mkdir_p(File.dirname(config))
      File.write(prompt, "Prompt for <%= invocation.message.text %>")
      File.write(config, "# harness fixture\n")
      configuration = TestHarness.new
      configuration.select_agent agent
      configuration.instance_variable_set(:@resolved_model_resolver, models_for(provider, settings:))
      configuration.session_store = {provider: session_store_provider(session_store)} if session_store
      configure&.call(configuration)
      harness = configuration.runtime(root:)
      yield harness, provider, root
    end
  end

  def models_for(provider, settings: {})
    resolver = LittleGhost::ModelResolver.allocate
    resolver.define_singleton_method(:default_model) { "default" }
    resolver.define_singleton_method(:resolve) do |role, invocation: nil, **|
      profiles = invocation&.[](:model_configuration)&.fetch("profiles", {}) || {}
      overrides = profiles.fetch(role.to_s, {}).fetch("settings", {})
      LittleGhost::Model.new(provider:, target: "test:test", settings: settings.merge(overrides.transform_keys(&:to_sym)), role:)
    end
    resolver
  end

  def session_store_provider(store)
    Class.new(store.class) do
      define_singleton_method(:new) { |**| store }
    end
  end
end
