# frozen_string_literal: true

require "json"
require_relative "configuration"

module LittleGhost
  # Prepare the shared services that assemblies use across many runs.
  # A runtime owns model resolution, loading, persistence, lookup paths, hooks,
  # and resource factories for one Ruby setup.
  #
  #   configuration = LittleGhost::Configuration.new(
  #     root: Dir.pwd,
  #     providers: {
  #       openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
  #     },
  #     models: {customer_support: {target: "openai:gpt-5.6-luna"}},
  #     default_model: "customer_support",
  #     service_name: "support-api"
  #   )
  #   runtime = LittleGhost::Runtime.new(configuration: configuration)
  #
  #   runtime.service_name # => "support-api"
  #   runtime.root == Pathname.new(File.realpath(Dir.pwd)) # => true
  #
  # Without explicit +settings+, construction canonicalizes the root, loads
  # +config/little_ghost.rb+ once through the Configuration, snapshots settings,
  # configures instrumentation, eager-loads application constants, and builds the
  # selected model resolver and session store. Supplying +settings+ is the
  # lower-level path used to create a sibling runtime from an existing snapshot.
  #
  # Reuse a runtime across runs. +build_run+ creates any missing workspace and
  # sandbox, transfers ownership only after both are built, and closes partial
  # resources if construction fails. +build+ creates a sibling with explicit
  # overrides and reuses the loader only when the application root is unchanged.
  #
  # Startup emits structured lifecycle instrumentation; a failed phase emits a
  # failure event, flushes instrumentation, and re-raises the original exception.
  # Session actor resolution must use trusted authenticated identity for tenant
  # isolation. The default UnrestrictedSandbox is convenient application plumbing,
  # not a security boundary for untrusted work.
  class Runtime
    # The snapshotted setup and materialized services used by new runs.
    attr_reader :configuration, :settings, :root, :loader, :prompt_paths, :skill_paths,
      :skill_resource_root, :model_resolver, :session_store, :workspace_class, :sandbox_class,
      :runtime_hooks

    # Starts a runtime from +configuration+ or an existing settings snapshot.
    def initialize(configuration:, settings: nil)
      @startup_started_at = monotonic_time
      @startup_phase = "configuration"
      @startup_reported = false

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
        report_startup(status: "starting")
        @startup_reported = true
        @root = canonical_application_root(@settings.fetch(:root))
        @skill_resource_root = @settings[:skill_resource_root]
        @workspace_class = @settings.fetch(:workspace)
        @sandbox_class = @settings.fetch(:sandbox)
        @runtime_hooks = build_runtime_hooks(@settings[:runtime_hooks])

        @startup_phase = "instrumentation"
        subscribe_instrumentation(@settings[:instrumentation_subscribers])
        emit_startup(:runtime_start)

        @startup_phase = "loader"
        @loader = @settings[:loader] || Support::Loader.new(root: @root)
        loader.setup
        loader.eager_load

        @startup_phase = "model_resolver"
        @invocation_class = @settings[:invocation] || Invocation
        @model_resolver = @settings.fetch(:model_resolver)
        @default_model = @settings.fetch(:default_model, "default").to_s

        @startup_phase = "session_store"
        @session_store = build_session_store(@settings[:session_store])
        @session_actor = @settings[:session_actor]

        @startup_phase = "prompts"
        @prompt_paths = build_lookup_paths(:prompt_paths)
        @skill_paths = build_lookup_paths(:skill_paths)

        @startup_phase = "agent_factory"
        @agent_factory = AgentFactory.new(
          runtime: self,
          prompt_paths: @prompt_paths,
          resolve_agent: method(:resolve_agent_class)
        )

        @startup_phase = "complete"
        emit_startup(:runtime_stop, outcome: "ready")
        report_startup(status: "ready")
      rescue => error
        unless @startup_reported
          report_startup(status: "starting")
          @startup_reported = true
        end
        emit_startup(:runtime_stop, outcome: "failed", error:)
        Instrumentation.flush
        report_startup(status: "failed", error:)
        raise
      end
    end

    # Creates a sibling runtime with explicit setting overrides.
    def build(**overrides)
      values = @settings.merge(overrides)
      values[:root] = canonical_application_root(values.fetch(:root))
      values[:loader] = loader unless overrides.key?(:loader) || overrides.key?(:root)
      self.class.new(
        configuration:,
        settings: values
      )
    end

    # Coerces an application payload into the configured Invocation class.
    def parse(payload)
      payload.is_a?(@invocation_class) ? payload : @invocation_class.new(payload)
    end

    # Creates a Run and transfers ownership of newly created workspace and
    # sandbox resources to it.
    def build_run(
      payload,
      agent_class: nil,
      assembly_class: nil,
      entrypoint_class: nil,
      execution_class: nil,
      cancellation_token: Support::CancellationToken.new,
      workspace: nil,
      sandbox: nil
    )
      entrypoint_class ||= assembly_class || agent_class
      raise ArgumentError, "entrypoint_class is required" unless entrypoint_class

      execution_class ||= assembly_class || entrypoint_class
      agent_class ||= entrypoint_class if entrypoint_class <= Agent
      owned_resources = []
      workspace ||= build_workspace.tap { |resource| owned_resources << resource }
      sandbox ||= build_sandbox(workspace:).tap { |resource| owned_resources << resource }
      run = Run.new(
        invocation: parse(payload),
        runtime: self,
        agent_class:,
        entrypoint_class:,
        execution_class:,
        cancellation_token:,
        workspace:,
        sandbox:
      )
      owned_resources.each { |resource| run.register(resource) }
      prepare_run(run)
    rescue
      if run
        run.close
      else
        close_resources(owned_resources)
      end
      raise
    end

    # Instantiates the configured workspace, or a root-scoped Workspace by default.
    def build_workspace
      return workspace_class.new if workspace_class

      Workspace.new(root: root)
    end

    # Instantiates the configured sandbox around +workspace+, or an unrestricted
    # sandbox by default.
    def build_sandbox(workspace:)
      return sandbox_class.new(workspace:) if sandbox_class

      UnrestrictedSandbox.new(workspace:)
    end

    # :nodoc:
    def build_agent(
      agent_class_or_name,
      run:,
      model: nil,
      tools: [],
      agent_path: Subagents::AgentPath::ROOT
    )
      agent_class_or_name = agent_class_or_name.definition if agent_class_or_name.is_a?(AgentBuilder)
      if agent_class_or_name.is_a?(AssemblyDefinition)
        unless agent_class_or_name.kind == :agent
          raise ConfigurationError, "agent definition must have kind :agent"
        end
        agent_class_or_name = agent_class_or_name.implementation
      end
      @agent_factory.build(agent_class_or_name, run:, model:, tools:, agent_path:)
    end

    # Builds an Agent through AgentFactory or constructs another Assembly for +run+.
    def build_assembly(assembly_class_or_name, run:, **options) # :nodoc:
      if assembly_class_or_name.is_a?(AssemblyBuilder)
        assembly_class_or_name = assembly_class_or_name.definition
      end
      if assembly_class_or_name.is_a?(Class) && assembly_class_or_name <= Assembly
        assembly_class_or_name = assembly_class_or_name.definition
      end
      if assembly_class_or_name.is_a?(AssemblyDefinition)
        return build_agent(assembly_class_or_name, run:, **options) if assembly_class_or_name.kind == :agent
        raise ArgumentError, "composite assembly definitions do not accept agent build options" unless options.empty?

        return assembly_class_or_name.implementation.new(run:, runtime: self)
      end
      if !assembly_class_or_name.is_a?(Class) || assembly_class_or_name <= Agent
        return build_agent(assembly_class_or_name, run:, **options)
      end
      unless assembly_class_or_name <= Assembly
        raise ConfigurationError, "assembly must inherit from LittleGhost::Assembly"
      end
      unless options.empty?
        raise ArgumentError, "composite assemblies do not accept agent build options"
      end

      assembly_class_or_name.new(run:, runtime: self)
    end

    # The low-cardinality service name attached to runtime telemetry.
    def service_name
      @settings&.[](:service_name) || default_service_name
    end

    def model_for(agent_class, run) # :nodoc:
      selection = agent_class.model_selection(run.invocation) || @default_model
      model_resolver.resolve(selection, invocation: run.invocation, context: run)
    end

    def open_session(run) # :nodoc:
      Session.new(
        id: run.invocation.session_id,
        actor_id: session_actor_for(run.invocation),
        store: session_store,
        operation_id: run.operation_id
      )
    end

    def session_history(run, session, fallback:) # :nodoc:
      stored = session.history
      runtime_hooks.each do |hook|
        history = hook.session_history(run, stored:, fallback:)
        return normalize_history(history) unless history.nil?
      end

      session.history(fallback:)
    end

    def prepare_run(run) # :nodoc:
      runtime_hooks.each { |hook| hook.prepare_run(run) }
      run
    end

    def prepare_interruption(run, payload) # :nodoc:
      runtime_hooks.reduce(payload) do |prepared, hook|
        hook.prepare_interruption(run, prepared)
      end
    end

    def open_subagent_session(run, conversation_id) # :nodoc:
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

    def session_actor_for(invocation) # :nodoc:
      @session_actor ? @session_actor.call(invocation) : invocation.actor_id
    end

    def template_locals(run:, agent:) # :nodoc:
      {invocation: run.invocation, run:, agent:}.merge(agent.prompt_locals)
    end

    def error_message(error, run) # :nodoc:
      runtime_hooks.each do |hook|
        message = hook.error_message(error, run)
        return message if message
      end

      default_error_message(error, run)
    end

    def default_error_message(error, _run) # :nodoc:
      return error.message if error.is_a?(UnsupportedInputError)
      return error.message if error.is_a?(ToolLoopError)
      return "The model reached its output limit before completing a response. Please retry with a narrower request." if error.is_a?(OutputLimitError)
      if error.is_a?(MalformedToolCallError)
        return "The model returned an invalid tool call before completing the response. Please retry with a narrower request."
      end

      "Agent failed: #{error.class}"
    end

    def resolve_agent(value) # :nodoc:
      resolve_agent_class(value)
    end

    private

    def close_resources(resources)
      resources.reverse_each do |resource|
        resource.close if resource.respond_to?(:close)
      rescue
        nil
      end
    end

    def build_service(value, default:)
      value ||= default.call
      value.is_a?(Class) ? value.new : value
    end

    def build_runtime_hooks(hook_classes)
      Array(hook_classes).map(&:new)
    end

    def normalize_history(history)
      Array(history).map { |message| Message.coerce(message) }.freeze
    end

    def build_session_store(definition)
      return SessionStores::Memory.new unless definition

      provider = definition.fetch(:provider)
      options = definition.except(:provider)
      store = provider.new(**options)
      unless store.is_a?(SessionStore)
        raise ConfigurationError, "session_store must be a LittleGhost::SessionStore"
      end

      store
    end

    def subscribe_instrumentation(subscribers)
      Array(subscribers).each { |subscriber| Instrumentation.subscribe(subscriber) }
    end

    def default_service_name
      return @settings[:service_name].to_s if @settings&.[](:service_name)

      "little-ghost"
    end

    def emit_startup(name, outcome: nil, error: nil)
      attributes = {
        service_name: service_name,
        startup_phase: @startup_phase,
        duration_ms: startup_duration_ms,
        outcome:
      }.compact
      if error
        attributes[:error_type] = error.class.name
        attributes[:diagnostic_exception] = JSON.generate(diagnostic_exception(error))
      end
      if name == :runtime_start
        @startup_handle = Instrumentation.start(:runtime, parent: nil, **attributes)
      else
        @startup_handle&.finish(**attributes)
      end
    end

    def report_startup(status:, error: nil)
      payload = {
        status:,
        phase: @startup_phase,
        service_name:
      }
      payload[:duration_ms] = startup_duration_ms unless status == "starting"
      payload[:error_type] = error.class.name if error
      return Events.error("little_ghost.runtime.startup", payload) if error

      Events.info("little_ghost.runtime.startup", payload)
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
      PathSet.new(roots)
    end
  end
end
