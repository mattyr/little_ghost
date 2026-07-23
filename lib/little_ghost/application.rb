# frozen_string_literal: true

require "logger"
require "pathname"

module LittleGhost
  class Application
    class << self
      CONFIGURATION_KEYS = %i[agent invocation models default_model instrumentation service_name].freeze

      def inherited(subclass)
        super
        configuration = application_configuration.dup
        configuration[:components] = Array(configuration[:components]).dup
        configuration[:instruments] = Array(configuration[:instruments]).dup
        subclass.instance_variable_set(:@application_configuration, configuration)
        subclass.instance_variable_set(:@application_source_path, caller_locations(1, 1).first&.absolute_path)
      end

      CONFIGURATION_KEYS.each do |name|
        define_method(name) do |value = :__read__|
          return application_configuration[name] if value == :__read__

          ensure_not_booted!
          application_configuration[name] = (name == :default_model) ? value.to_s : value
        end
      end

      def application_configuration
        @application_configuration ||= {components: [], instruments: []}
      end

      def configure(&block)
        class_eval(&block) if block
        self
      end

      def instrument(installer, **options)
        ensure_not_booted!
        application_configuration[:instruments] << [installer, options]
        installer
      end

      def session_store(value = :__read__, &factory)
        return application_configuration[:session_store] if value == :__read__ && !factory

        ensure_not_booted!
        raise ArgumentError, "Provide a session store or a block, not both" if value != :__read__ && factory

        application_configuration[:session_store] = factory || value
      end

      def session_actor(value = :__read__, &resolver)
        return application_configuration[:session_actor] if value == :__read__ && !resolver

        ensure_not_booted!
        raise ArgumentError, "Provide a session actor resolver or a block, not both" if value != :__read__ && resolver

        configured = resolver || value
        unless configured.respond_to?(:call)
          raise ArgumentError, "session_actor must be callable"
        end

        application_configuration[:session_actor] = configured
      end

      def root(value = :__read__)
        if value != :__read__
          ensure_not_booted!
          return application_configuration[:root] = canonical_root(value)
        end

        configured = application_configuration[:root]
        configured ? canonical_root(configured) : inferred_root
      end

      def component(value = nil, root: nil)
        ensure_not_booted!
        configured = value || Component.new(root: root)
        raise ArgumentError, "component must be a LittleGhost::Component" unless configured.is_a?(Component)

        application_configuration[:components] << configured
        configured
      end

      def build(**overrides)
        values = (@boot_configuration || unbooted_configuration).merge(overrides)
        values[:loader] = loader_for(values.fetch(:root)) unless overrides.key?(:loader)
        new(values)
      end

      def boot!(root: nil)
        return @booted_application if @booted_application

        (@boot_mutex ||= Mutex.new).synchronize do
          return @booted_application if @booted_application

          values = application_configuration.dup
          values[:components] = Array(values[:components]).dup
          values[:root] = root || values[:root] || self.root
          values[:loader] ||= loader_for(values.fetch(:root))
          @boot_configuration = Support.immutable(values)
          @booted_application = new(@boot_configuration)
        end
      end

      def boot_configuration
        boot!
        @boot_configuration
      end

      def call(payload) = boot!.call(payload)
      def stream(payload) = boot!.stream(payload)

      private

      def ensure_not_booted!
        raise ConfigurationError, "#{self} is already booted" if @booted_application
      end

      def inferred_root
        source = @application_source_path
        directory = source && File.dirname(source)
        while directory
          return canonical_root(directory) if File.file?(File.join(directory, "config/application.rb"))

          parent = File.dirname(directory)
          break if parent == directory
          directory = parent
        end
        raise ConfigurationError, "Could not infer #{self}.root; define root explicitly"
      end

      def canonical_root(value)
        path = Pathname.new(File.realpath(File.expand_path(value)))
        raise ConfigurationError, "application root must be a directory" unless path.directory?

        path
      rescue Errno::ENOENT
        raise ConfigurationError, "application root must exist"
      end

      def unbooted_configuration
        values = application_configuration.dup
        values[:components] = Array(values[:components]).dup
        values[:instruments] = Array(values[:instruments]).dup
        values[:root] = values[:root] || root
        Support.immutable(values)
      end

      def loader_for(root)
        path = canonical_root(root).to_s
        (@loader_mutex ||= Mutex.new).synchronize do
          (@application_loaders ||= {})[path] ||= Support::Loader.new(root: path)
        end
      end
    end

    attr_reader :root, :loader, :components, :instrumentation, :models, :session_store, :agent_class

    def initialize(configuration)
      @configuration = configuration
      @root = canonical_application_root(configuration.fetch(:root))
      @loader = configuration[:loader] || Support::Loader.new(root: @root)
      @components = Array(configuration[:components]).freeze
      loaders = [loader, *components.map(&:loader)]
      validate_loader_conflicts!(loaders)
      loaders.each(&:setup)
      loaders.each(&:eager_load)
      @agent_class = resolve_agent_class(configuration[:agent] || default_agent_name)
      @invocation_class = configuration[:invocation] || Invocation
      @models = build_service(configuration[:models], default: -> { ModelRegistry.new })
      @default_model = configuration.fetch(:default_model, "default").to_s
      @instrumentation = build_service(
        configuration[:instrumentation],
        default: -> { Support::Instrumentation.new }
      )
      install_instrumentation(configuration[:instruments])
      @session_store = build_session_store(configuration[:session_store])
      @session_actor = configuration[:session_actor]
      @prompt_paths = discover_prompt_paths
      @agent_builder = AgentBuilder.new(
        application: self,
        primary_agent: @agent_class,
        prompt_paths: @prompt_paths,
        resolve_agent: method(:resolve_agent_class)
      )
    end

    def parse(payload)
      payload.is_a?(@invocation_class) ? payload : @invocation_class.new(payload)
    end

    def build_run(payload)
      Run.new(invocation: parse(payload), application: self)
    end

    def call(payload)
      build_run(payload).call
    end

    def stream(payload)
      build_run(payload).each
    end

    def build_agent(agent_class_or_name = @agent_class, run:, model: nil, tools: [])
      @agent_builder.build(agent_class_or_name, run:, model:, tools:)
    end

    def model_for(agent_class, run)
      role = agent_class.model_role(run.invocation) || @default_model
      models.resolve(role, invocation: run.invocation, run:)
    end

    def open_session(run)
      Session.new(
        id: run.invocation.session_id,
        actor_id: session_actor_for(run.invocation),
        store: session_store
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

    private

    def build_service(value, default:)
      value ||= default.call
      value.is_a?(Class) ? value.new : value
    end

    def build_session_store(value)
      store = value.is_a?(Proc) ? value.call : value
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

      name = self.class.name.to_s
      return "little-ghost" if name.empty?

      name.delete_suffix("Application").gsub("::", "-")
        .gsub(/([a-z\d])([A-Z])/, '\\1-\\2').downcase
    end

    def canonical_application_root(value)
      path = Pathname.new(File.realpath(File.expand_path(value)))
      raise ConfigurationError, "application root must be a directory" unless path.directory?

      path.freeze
    rescue Errno::ENOENT
      raise ConfigurationError, "application root must exist"
    end

    def default_agent_name
      parts = self.class.name.to_s.split("::")
      raise ConfigurationError, "agent must be configured for anonymous applications" if parts.empty?

      leaf = parts.pop.delete_suffix("Application")
      return "#{leaf}Agent" unless leaf.empty?
      raise ConfigurationError, "agent must be configured for anonymous applications" if parts.empty?

      "#{parts.join("::")}::Agent"
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
