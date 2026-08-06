# frozen_string_literal: true

require_relative "configuration"

module LittleGhost
  class Runtime
    class << self
      def loader_for(root)
        path = canonical_root(root).to_s
        (@loader_mutex ||= Mutex.new).synchronize do
          (@loaders ||= {})[path] ||= Support::Loader.new(root: path)
        end
      end

      private

      def canonical_root(value)
        Pathname.new(File.realpath(File.expand_path(value)))
      rescue Errno::ENOENT
        raise ConfigurationError, "application root must exist"
      end
    end

    attr_reader :configuration, :root, :loader, :components, :instrumentation, :models, :session_store, :agent_class,
      :entrypoint, :entrypoint_class

    def initialize(configuration:, entrypoint: nil, agent: nil)
      raise ArgumentError, "Provide an entrypoint or agent, not both" if entrypoint && agent

      configured_entrypoint = entrypoint || agent
      configuration_store = configuration if configuration.respond_to?(:load_file!)
      bootstrap_root = configuration_store && canonical_application_root(configuration_store.root)
      if configuration_store
        @loader = self.class.loader_for(bootstrap_root)
        configuration_store.load_file!(root: bootstrap_root)
        @configuration = configuration_store.settings(root: bootstrap_root)
      else
        @configuration = configuration
      end

      @root = canonical_application_root(@configuration.fetch(:root))
      @loader = @configuration[:loader] || @loader || self.class.loader_for(@root)
      @components = Array(@configuration[:components]).freeze
      loaders = [loader, *components.map(&:loader)]
      validate_loader_conflicts!(loaders)
      loaders.each(&:setup)
      loaders.each(&:eager_load)
      configured_entrypoint ||= @configuration[:entrypoint] || @configuration[:agent] || Agent
      @entrypoint_class = resolve_entrypoint_class(
        configured_entrypoint.is_a?(Agent) ? configured_entrypoint.class : configured_entrypoint
      )
      @agent_class = if entrypoint && !agent
        @entrypoint_class
      elsif agent
        resolve_agent_class(agent)
      elsif @configuration[:agent]
        resolve_agent_class(@configuration[:agent])
      elsif @entrypoint_class <= Agent
        @entrypoint_class
      else
        Agent
      end
      @entrypoint = if configured_entrypoint.is_a?(Agent)
        configured_entrypoint
      elsif @entrypoint_class <= Agent
        @entrypoint_class.new
      end
      @invocation_class = @configuration[:invocation] || Invocation
      @models = build_service(@configuration[:models], default: -> { ModelRegistry.new })
      @default_model = @configuration.fetch(:default_model, "default").to_s
      @instrumentation = build_service(
        @configuration[:instrumentation],
        default: -> { Support::Instrumentation.new }
      )
      install_instrumentation(@configuration[:instruments])
      @session_store = build_session_store(@configuration[:session_store])
      @session_actor = @configuration[:session_actor]
      @prompt_paths = discover_prompt_paths
      @agent_builder = AgentBuilder.new(
        configuration: self,
        primary_agent: @agent_class,
        prompt_paths: @prompt_paths,
        resolve_agent: method(:resolve_agent_class)
      )
      @entrypoint.instance_variable_set(:@runtime, self) if @entrypoint&.is_a?(Agent)
    end

    def build(**overrides)
      values = configuration.merge(overrides)
      values[:root] = canonical_application_root(values.fetch(:root))
      values[:loader] = loader unless overrides.key?(:loader) || overrides.key?(:root)
      self.class.new(configuration: values, entrypoint: @entrypoint_class)
    end

    def parse(payload)
      payload.is_a?(@invocation_class) ? payload : @invocation_class.new(payload)
    end

    def build_run(payload)
      run_class = @agent_class.respond_to?(:run_class) ? @agent_class.run_class : Run
      run_class.new(invocation: parse(payload), configuration: self, agent_class: @agent_class,
        entrypoint_class: @entrypoint_class)
    end

    def call(payload = nil, **options)
      build_run(payload || options).call
    end

    def stream(payload = nil, **options)
      build_run(payload || options).each
    end

    def build_agent(
      agent_class_or_name = @agent_class,
      run:,
      model: nil,
      tools: [],
      agent_path: Subagents::AgentPath::ROOT
    )
      @agent_builder.build(agent_class_or_name, run:, model:, tools:, agent_path:)
    end

    def build_entrypoint(run:)
      return @entrypoint_class.new(run:) if workflow_entrypoint?

      return build_agent(run:) if @entrypoint_class == @agent_class

      build_agent(@entrypoint_class, run:)
    end

    def workflow_entrypoint? = @entrypoint_class <= Workflow

    def entrypoint_name
      workflow_entrypoint? ? @entrypoint_class.name.to_s : @entrypoint_class.agent_id
    end

    def service_name
      @configuration[:service_name] || default_service_name
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

      "#{@agent_class.agent_id} failed: #{error.class}"
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
      return @configuration[:service_name].to_s if @configuration[:service_name]

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

    def resolve_entrypoint_class(value)
      klass = if value.is_a?(String) || value.is_a?(Symbol)
        Object.const_get(value.to_s)
      else
        value
      end
      unless klass.is_a?(Class) && [Agent, Workflow].any? { |base| klass <= base }
        raise ConfigurationError, "entrypoint must inherit from LittleGhost::Agent or LittleGhost::Workflow"
      end

      klass
    rescue NameError
      klass = loader.constant(value)
      unless klass.is_a?(Class) && [Agent, Workflow].any? { |base| klass <= base }
        raise ConfigurationError, "entrypoint must inherit from LittleGhost::Agent or LittleGhost::Workflow"
      end

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
