# frozen_string_literal: true

require_relative "configuration"

module LittleGhost
  class Runtime
    attr_reader :configuration, :settings, :root, :loader, :components, :instrumentation, :models, :session_store

    def initialize(configuration:, settings: nil)
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
      @loader = @settings[:loader] || Support::Loader.new(root: @root)
      @components = Array(@settings[:components])
      loaders = [loader, *components.map(&:loader)]
      validate_loader_conflicts!(loaders)
      loaders.each(&:setup)
      loaders.each(&:eager_load)
      @invocation_class = @settings[:invocation] || Invocation
      @models = build_service(@settings[:models], default: -> { ModelRegistry.new })
      @default_model = @settings.fetch(:default_model, "default").to_s
      @instrumentation = build_service(
        @settings[:instrumentation],
        default: -> { Support::Instrumentation.new }
      )
      install_instrumentation(@settings[:instruments])
      @session_store = build_session_store(@settings[:session_store])
      @session_actor = @settings[:session_actor]
      @prompt_paths = discover_prompt_paths
      @agent_builder = AgentBuilder.new(
        runtime: self,
        prompt_paths: @prompt_paths,
        resolve_agent: method(:resolve_agent_class)
      )
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

    def discover_prompt_paths
      paths = []
      application_path = File.join(root, "app/prompts")
      if File.exist?(application_path) || File.symlink?(application_path)
        resolved = File.realpath(application_path)
        unless File.directory?(resolved) && inside_root?(resolved, root)
          raise Support::Loader::ConflictError, "Application prompt directory escapes application root: #{application_path}"
        end
        paths << Templates::Root.new(path: resolved, boundary: root)
      end
      paths.concat(components.flat_map(&:prompt_paths)).freeze
    rescue Errno::ENOENT
      raise Support::Loader::ConflictError, "Application prompt directory is invalid: #{application_path}"
    end

    def inside_root?(path, boundary)
      path.to_s == boundary.to_s || path.to_s.start_with?("#{boundary}#{File::SEPARATOR}")
    end

    def validate_loader_conflicts!(loaders)
      owners = {}
      loaders.each do |candidate|
        candidate.registered_constants.each do |constant_name, path|
          validate_existing_constant!(constant_name, owner: candidate)
          conflict = owners.keys.find do |owned|
            owned == constant_name || owned.start_with?("#{constant_name}::") || constant_name.start_with?("#{owned}::")
          end
          if conflict
            raise Support::Loader::ConflictError,
              "Conflicting constant mappings: #{conflict} (#{owners[conflict]}) and #{constant_name} (#{path})"
          end
          owners[constant_name] = path
        end
      end
    end

    def validate_existing_constant!(constant_name, owner:)
      return if owner.loaded_constant?(constant_name)

      names = constant_name.split("::")
      leaf = names.pop
      namespace = Object
      names.each do |name|
        raise Support::Loader::ConflictError, "Existing autoload conflicts with #{constant_name}" if namespace.autoload?(name)
        unless namespace.const_defined?(name, false)
          namespace = nil
          break
        end

        namespace = namespace.const_get(name, false)
        raise Support::Loader::ConflictError, "#{name} is not a namespace for #{constant_name}" unless namespace.is_a?(Module)
      end
      return unless namespace

      if namespace.const_defined?(leaf, false) || namespace.autoload?(leaf)
        raise Support::Loader::ConflictError, "#{constant_name} is already defined"
      end
    end
  end
end
