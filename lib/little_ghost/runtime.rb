# frozen_string_literal: true

require "json"
require "logger"
require "securerandom"
require_relative "configuration"

module LittleGhost
  class Runtime
    attr_reader :configuration, :settings, :root, :loader, :prompt_paths, :skill_paths,
      :skill_resource_root, :instrumentation, :models, :session_store

    def initialize(configuration:, settings: nil, logger: Logger.new($stderr))
      @logger = logger
      @startup_operation_id = SecureRandom.uuid
      @startup_started_at = monotonic_time
      @startup_phase = "configuration"
      log_startup(status: "starting")

      begin
        raise ArgumentError, "configuration must be a LittleGhost::Configuration" unless configuration.is_a?(Configuration)

        @configuration = configuration
        if settings
          @settings = settings
        else
          bootstrap_root = canonical_application_root(configuration.root)
          configuration.load_file!(root: bootstrap_root)
          @settings = configuration.settings(root: bootstrap_root)
        end
        @root = canonical_application_root(@settings.fetch(:root))
        @skill_resource_root = @settings[:skill_resource_root]

        @startup_phase = "instrumentation"
        @instrumentation = build_service(
          @settings[:instrumentation],
          default: -> { Support::Instrumentation.new }
        )
        install_instrumentation(@settings[:instruments])
        emit_startup(:runtime_start)

        @startup_phase = "loader"
        @loader = @settings[:loader] || Support::Loader.new(root: @root)
        loader.setup
        loader.eager_load

        @startup_phase = "models"
        @invocation_class = @settings[:invocation] || Invocation
        @models = build_service(@settings[:models], default: -> { ModelRegistry.new })
        @default_model = @settings.fetch(:default_model, "default").to_s

        @startup_phase = "session_store"
        @session_store = build_session_store(@settings[:session_store])
        @session_actor = @settings[:session_actor]

        @startup_phase = "prompts"
        @prompt_paths = build_lookup_paths(:prompt_paths)
        @skill_paths = build_lookup_paths(:skill_paths)

        @startup_phase = "agent_builder"
        @agent_builder = AgentBuilder.new(
          runtime: self,
          prompt_paths: @prompt_paths,
          resolve_agent: method(:resolve_agent_class)
        )

        @startup_phase = "complete"
        emit_startup(:runtime_stop, outcome: "ready")
        log_startup(status: "ready")
      rescue => error
        emit_startup(:runtime_stop, outcome: "failed", error:) if @instrumentation
        @instrumentation&.flush
        log_startup(status: "failed", error:)
        raise
      end
    end

    def build(**overrides)
      values = @settings.merge(overrides)
      values[:root] = canonical_application_root(values.fetch(:root))
      values[:loader] = loader unless overrides.key?(:loader) || overrides.key?(:root)
      self.class.new(
        configuration:,
        settings: values
      )
    end

    def parse(payload)
      payload.is_a?(@invocation_class) ? payload : @invocation_class.new(payload)
    end

    def build_run(payload, agent_class:, entrypoint_class: agent_class)
      run_class = agent_class.respond_to?(:run_class) ? agent_class.run_class : Run
      run_class.new(invocation: parse(payload), runtime: self, agent_class:, entrypoint_class:)
    end

    def build_agent(
      agent_class_or_name,
      run:,
      model: nil,
      tools: [],
      agent_path: Subagents::AgentPath::ROOT
    )
      @agent_builder.build(agent_class_or_name, run:, model:, tools:, agent_path:)
    end

    def service_name
      @settings[:service_name] || default_service_name
    end

    def model_for(agent_class, run)
      role = agent_class.model_role(run.invocation) || @default_model
      models.resolve(role, invocation: run.invocation, run:)
    end

    def open_session(run)
      Session.new(
        id: run.invocation.session_id,
        actor_id: session_actor_for(run.invocation),
        store: session_store,
        operation_id: run.operation_id
      )
    end

    def open_subagent_session(run, conversation_id)
      parent_link = Subagents::Manager.parent_link(run.session)
      Session.new(
        id: Subagents::Manager.conversation_session_id(conversation_id),
        actor_id: session_actor_for(run.invocation),
        store: session_store,
        operation_id: run.operation_id,
        metadata: {
          "little_ghost_kind" => "subagent_conversation",
          "little_ghost_parent_link" => parent_link,
          "little_ghost_conversation_id" => conversation_id
        }
      )
    end

    def session_actor_for(invocation)
      @session_actor ? @session_actor.call(invocation) : invocation.actor_id
    end

    def template_locals(run:, agent:)
      {invocation: run.invocation, run:, agent:}.merge(agent.prompt_locals)
    end

    def instrumentation_attributes(run:, agent: nil)
      {}
    end

    def error_message(error, _run)
      return error.message if error.is_a?(UnsupportedInputError)
      return error.message if error.is_a?(ToolLoopError)
      return "The model reached its output limit before completing a response. Please retry with a narrower request." if error.is_a?(OutputLimitError)
      if error.is_a?(MalformedToolCallError)
        return "The model returned an invalid tool call before completing the response. Please retry with a narrower request."
      end

      "Agent failed: #{error.class}"
    end

    def resolve_agent(value)
      resolve_agent_class(value)
    end

    private

    def build_service(value, default:)
      value ||= default.call
      value.is_a?(Class) ? value.new : value
    end

    def build_session_store(value)
      store = if value.is_a?(Proc)
        value.arity.zero? ? value.call : value.call(self)
      else
        value
      end
      store ||= SessionStores::Memory.new
      unless store.is_a?(SessionStore)
        raise ConfigurationError, "session_store must be a LittleGhost::SessionStore"
      end

      store
    end

    def install_instrumentation(declarations)
      Array(declarations).each do |installer, options|
        provider = if installer.is_a?(Class) && !installer.respond_to?(:install)
          installer.new
        else
          installer
        end
        unless provider.respond_to?(:install)
          raise ConfigurationError, "instrument must respond to install"
        end

        installation_options = {service_name: default_service_name}.merge(options)
        provider.install(instrumentation:, **installation_options)
      end
    end

    def default_service_name
      return @settings[:service_name].to_s if @settings[:service_name]

      "little-ghost"
    end

    def emit_startup(name, outcome: nil, error: nil)
      attributes = {
        operation_id: @startup_operation_id,
        service_name: service_name,
        startup_phase: @startup_phase,
        duration_ms: startup_duration_ms,
        outcome:
      }.compact
      if error
        attributes[:error_type] = error.class.name
        attributes[:diagnostic_exception] = JSON.generate(diagnostic_exception(error))
      end
      @instrumentation.emit(name, **attributes)
    end

    def log_startup(status:, error: nil)
      values = [
        "little_ghost_runtime_boot",
        "status=#{status}",
        "phase=#{@startup_phase}"
      ]
      values << "service_name=#{service_name}" if @settings
      values << "duration_ms=#{startup_duration_ms}" if status != "starting"
      if error
        values << "error=#{error.class}"
        values << "message=#{error.message.inspect}"
      end
      level = error ? :error : :info
      @logger.public_send(level, values.join(" "))
    end

    def diagnostic_exception(error)
      {
        type: error.class.name,
        message: error.message,
        stacktrace: Array(error.backtrace).join("\n")
      }
    end

    def startup_duration_ms
      ((monotonic_time - @startup_started_at) * 1_000).round(3)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def canonical_application_root(value)
      path = Pathname.new(File.realpath(File.expand_path(value)))
      raise ConfigurationError, "application root must be a directory" unless path.directory?

      path.freeze
    rescue Errno::ENOENT
      raise ConfigurationError, "application root must exist"
    end

    def resolve_agent_class(value)
      klass = if value.is_a?(String) || value.is_a?(Symbol)
        Object.const_get(value.to_s)
      else
        value
      end
      raise ConfigurationError, "agent must inherit from LittleGhost::Agent" unless klass.is_a?(Class) && klass <= Agent

      klass
    rescue NameError
      klass = loader.constant(value)
      raise ConfigurationError, "agent must inherit from LittleGhost::Agent" unless klass.is_a?(Class) && klass <= Agent

      klass
    end

    def build_lookup_paths(name)
      configured = Array(@settings.fetch(name))
      default = if name == :prompt_paths
        Configuration::DEFAULT_PROMPT_PATHS
      else
        Configuration::DEFAULT_SKILL_PATHS
      end
      roots = configured.map do |path|
        expanded = File.expand_path(path, root)
        boundary = default.include?(path.to_s) ? root : nil
        Lookup::Root.new(path: expanded, boundary:)
      end
      Lookup::PathSet.new(roots)
    end
  end
end
