# frozen_string_literal: true

require "pathname"

module LittleGhost
  # Configure shared services and lookup rules before agents start.
  # A configuration collects model profiles, persistence, paths,
  # instrumentation, and runtime hooks for an application.
  #
  #   LittleGhost.configure do |config|
  #     config.default_model :customer_support
  #     config.service_name "support-api"
  #   end
  #
  #   LittleGhost.configuration.default_model # => "customer_support"
  #   LittleGhost.configuration.service_name  # => "support-api"
  #
  # Prompt and skill lookup paths default to +app/prompts+ and +app/skills+
  # under the application root. Applications may append shared roots or replace
  # the arrays entirely.
  #
  # Configuration is a mutable builder, while each Runtime owns a settings
  # snapshot. The first runtime for a root loads +config/little_ghost.rb+ once;
  # later mutations do not alter that runtime, and one configuration cannot load
  # files for two different roots.
  #
  # Session actor resolvers belong at an authentication boundary. Multi-tenant
  # applications should derive actor identity from trusted authenticated state,
  # not from an unverified request field.
  class Configuration
    FILE_LOAD_MUTEX = Mutex.new # :nodoc:
    CONFIGURATION_KEYS = %i[invocation service_name].freeze # :nodoc:
    DEFAULT_PROMPT_PATHS = ["app/prompts"].freeze # :nodoc:
    DEFAULT_SKILL_PATHS = ["app/skills"].freeze # :nodoc:

    ##
    # The request envelope class used to parse application payloads.
    #
    # :method: invocation
    # :call-seq:
    #   invocation() -> value
    #   invocation(value) -> value

    ##
    ##
    # The low-cardinality service name attached to instrumentation.
    #
    # :method: service_name
    # :call-seq:
    #   service_name() -> value
    #   service_name(value) -> value
    CONFIGURATION_KEYS.each do |name|
      define_method(name) do |value = :__read__|
        return configuration_values[name] if value == :__read__

        configuration_values[name] = value
      end
    end

    ##
    # Replaces the request envelope class for subsequently built runtimes.
    # :method: invocation=
    # :call-seq:
    #   invocation=(value) -> value

    ##
    # Replaces the model resolver declaration for subsequently built runtimes.
    # :method: model_resolver=
    # :call-seq:
    #   model_resolver=(value) -> value

    ##
    ##
    # Replaces the service name attached to telemetry from new runtimes.
    # :method: service_name=
    # :call-seq:
    #   service_name=(value) -> value
    CONFIGURATION_KEYS.each do |name|
      define_method("#{name}=") { |value| public_send(name, value) }
    end

    # Starts a mutable builder with optional +values+.
    #
    # Prompt paths default to +app/prompts+ and skill paths to +app/skills+.
    # Collection settings are copied so callers can safely reuse their input
    # arrays after construction.
    def initialize(values = {})
      @configuration_values = {
        prompt_paths: DEFAULT_PROMPT_PATHS.dup,
        skill_paths: DEFAULT_SKILL_PATHS.dup,
        skill_resource_root: nil,
        workspace: nil,
        sandbox: nil,
        instrumentation_subscribers: [],
        runtime_hooks: []
      }.merge(values)
      @configuration_values[:prompt_paths] = Array(@configuration_values[:prompt_paths]).dup
      @configuration_values[:skill_paths] = Array(@configuration_values[:skill_paths]).dup
      @configuration_values[:instrumentation_subscribers] = Array(
        @configuration_values[:instrumentation_subscribers]
      ).dup
      @configuration_values[:runtime_hooks] = Array(@configuration_values[:runtime_hooks]).dup
      @configuration_values[:provider_adapters] = @configuration_values.fetch(:provider_adapters, {}).dup
      @configuration_values[:catalog_sources] = Array(@configuration_values[:catalog_sources]).dup
      @configuration_values[:provider_credentials] ||= nil
    end

    # Yields this builder for setup and returns the same instance.
    def configure
      yield self if block_given?
      self
    end

    # Workspace declaration used for subsequently built runtimes.
    def workspace = configuration_values[:workspace]
    # Sandbox declaration used for subsequently built runtimes.
    def sandbox = configuration_values[:sandbox]
    # Session-store declaration used for subsequently built runtimes.
    def session_store = configuration_values[:session_store]

    # Trusted provider connections for the default or custom resolver.
    def providers(value = :__read__)
      return configuration_values[:providers] if value == :__read__

      unless value.is_a?(Hash) || value.is_a?(Providers::Configuration)
        raise ArgumentError, "providers must be a Hash or LittleGhost::Providers::Configuration"
      end

      configuration_values[:providers] = value
      reset_model_resolver
      value
    end

    # Replaces trusted provider connections for subsequently built runtimes.
    def providers=(value)
      providers(value)
    end

    # Logical model profiles for the default resolver.
    def models(value = :__read__)
      return configuration_values[:models] if value == :__read__
      raise ArgumentError, "models must be a Hash" unless value.is_a?(Hash)

      configuration_values[:models] = value
      reset_model_resolver
      value
    end

    # Replaces logical model profiles for subsequently built runtimes.
    def models=(value)
      models(value)
    end

    # Fallback logical role for the default resolver.
    def default_model(value = :__read__)
      return configuration_values[:default_model] if value == :__read__

      configuration_values[:default_model] = value.to_s
      reset_model_resolver
      value.to_s
    end

    # Replaces the fallback logical role and normalizes it to a String.
    def default_model=(value)
      default_model(value)
    end

    # Provider YAML path. The conventional path is optional; an explicitly set
    # path must exist when a runtime is built.
    def providers_path(value = :__read__) = configuration_path(:providers_path, "providers.yml", value)

    # Replaces the provider YAML path for subsequently built runtimes.
    def providers_path=(value)
      providers_path(value)
    end

    # Model YAML path. The conventional path is optional; an explicitly set
    # path must exist when a runtime is built.
    def models_path(value = :__read__) = configuration_path(:models_path, "models.yml", value)

    # Replaces the model YAML path for subsequently built runtimes.
    def models_path=(value)
      models_path(value)
    end

    # Installs a complete resolver override for subsequently built runtimes.
    def model_resolver(value = :__read__)
      if value != :__read__
        validate_model_resolver_class!(value)

        configuration_values[:model_resolver] = value
        @resolved_model_resolver = nil
        return value
      end

      @model_resolver_mutex ||= Mutex.new
      @model_resolver_mutex.synchronize do
        @resolved_model_resolver ||= begin
          providers = resolved_providers
          credential_resolver = configuration_values[:provider_credentials] || providers&.method(:credentials)
          configured = configuration_values[:model_resolver]
          if configured
            warn_ignored_model_configuration
            configured.new(
              providers:,
              provider_adapters: configuration_values[:provider_adapters],
              catalog_sources: configuration_values[:catalog_sources],
              credential_resolver:
            )
          else
            profiles, file_default = resolved_models
            ModelResolver.new(
              providers:,
              profiles:,
              default_model: configuration_values.fetch(:default_model, file_default),
              provider_adapters: configuration_values[:provider_adapters],
              catalog_sources: configuration_values[:catalog_sources],
              credential_resolver:
            )
          end
        end
      end
    end

    def model_resolver=(value)
      model_resolver(value)
    end

    # Registers a provider adapter factory under +name+.
    def provider_adapter(name, callable = nil, &factory)
      implementation = factory || callable
      if implementation.is_a?(Class)
        unless implementation <= Providers::Base
          raise ArgumentError, "provider adapter class must inherit LittleGhost::Providers::Base"
        end
      elsif !implementation.respond_to?(:call)
        raise ArgumentError, "provider adapter must be a Providers::Base class or callable factory"
      end

      configuration_values[:provider_adapters][name.to_s] = implementation
      @resolved_model_resolver = nil
      implementation
    end

    # Adds an explicit catalog source. Sources refresh only when callers invoke
    # ModelResolver#refresh!.
    def catalog_source(source)
      raise ArgumentError, "catalog source must be a Models::Catalog::Source" unless source.is_a?(Models::Catalog::Source)

      configuration_values[:catalog_sources] << source
      @resolved_model_resolver = nil
      source
    end

    # Installs a trusted callable that returns credential options for a named
    # provider connection when each executable model is constructed.
    def provider_credentials(callable = nil, &resolver)
      value = resolver || callable
      return configuration_values[:provider_credentials] unless value
      raise ArgumentError, "provider credential resolver must be callable" unless value.respond_to?(:call)

      configuration_values[:provider_credentials] = value
      @resolved_model_resolver = nil
      value
    end

    # Selects the Workspace subclass instantiated for each run.
    def workspace=(value)
      @configuration_values[:workspace] = component_class(value, Workspace, :workspace)
    end

    # Selects the Sandbox subclass instantiated around each run's workspace.
    def sandbox=(value)
      @configuration_values[:sandbox] = component_class(value, Sandbox, :sandbox)
    end

    # Selects session persistence with a +:provider+ and its constructor options.
    #
    # The provider must be a SessionStore subclass. Runtime construction creates
    # and owns the store instance.
    def session_store=(value)
      unless value.is_a?(Hash)
        raise ArgumentError, "session_store must be a hash with a provider"
      end

      provider = value[:provider]
      @configuration_values[:session_store] = value.merge(provider: component_class(provider, SessionStore, :session_store))
    end

    # Looks up an arbitrary setting by symbol or string-compatible name.
    def [](name)
      configuration_values.fetch(name.to_sym)
    end

    # Adds or replaces an arbitrary setting.
    def []=(name, value)
      configuration_values[name.to_sym] = value
    end

    # Replaces the application root after resolving it to a stable real path.
    def root=(value)
      root(value)
    end

    # Adds an Instrumentation::Subscriber to each new runtime and returns it.
    def instrument(subscriber)
      unless subscriber.is_a?(Instrumentation::Subscriber)
        raise ArgumentError, "instrumentation subscriber must be a LittleGhost::Instrumentation::Subscriber"
      end

      configuration_values[:instrumentation_subscribers] << subscriber
      subscriber
    end

    # :call-seq:
    #   log_events_to() -> :stdout, :stderr, nil
    #   log_events_to(destination) -> destination
    #
    # Sends structured framework events to +:stdout+ or +:stderr+. This setting
    # controls the process-wide Events console destination; the most recent
    # setting replaces it without changing other event listeners. By default,
    # events have no console destination. Passing +nil+ disables console output.
    # The console listener redacts sensitive values and writes one JSON object
    # per line.
    def log_events_to(destination = :__read__)
      return Events.console_output if destination == :__read__

      Events.console_output = destination
    end

    # Replaces the console destination for structured framework events.
    def log_events_to=(destination)
      log_events_to(destination)
    end

    # Adds a Runtime::Hook subclass to each new runtime and returns it.
    def runtime_hook(hook_class)
      unless hook_class.is_a?(Class) && hook_class <= Runtime::Hook
        raise ArgumentError, "runtime_hook must be a LittleGhost::Runtime::Hook class"
      end

      configuration_values[:runtime_hooks] << hook_class
      hook_class
    end

    # :call-seq:
    #   session_actor() -> callable, nil
    #   session_actor(callable) -> callable
    #   session_actor { |invocation| ... } -> callable
    #
    # The callable that derives the persistence actor for each invocation.
    #
    # Pass either a callable or a block. The configured resolver should use
    # trusted authenticated identity in multi-tenant applications.
    def session_actor(value = :__read__, &resolver)
      return configuration_values[:session_actor] if value == :__read__ && !resolver

      raise ArgumentError, "Provide a session actor resolver or a block, not both" if value != :__read__ && resolver

      configured = resolver || value
      raise ArgumentError, "session_actor must be callable" unless configured.respond_to?(:call)

      configuration_values[:session_actor] = configured
    end

    # :call-seq:
    #   root() -> Pathname
    #   root(path) -> Pathname
    #
    # The resolved application root, defaulting to +Dir.pwd+.
    #
    # Setting or reading an invalid root raises ConfigurationError. Symlinks are
    # resolved so runtimes and lookup paths share one stable boundary.
    def root(value = :__read__)
      if value != :__read__
        return configuration_values[:root] = canonical_root(value)
      end

      configured = configuration_values[:root]
      configured ? canonical_root(configured) : inferred_root
    end

    # Mutable prompt lookup paths, in precedence order.
    def prompt_paths = configuration_values[:prompt_paths]

    # Replaces prompt lookup paths with +value+ converted to an Array.
    def prompt_paths=(value)
      configuration_values[:prompt_paths] = Array(value)
    end

    # Mutable skill lookup paths, in precedence order.
    def skill_paths = configuration_values[:skill_paths]

    # Replaces skill lookup paths with +value+ converted to an Array.
    def skill_paths=(value)
      configuration_values[:skill_paths] = Array(value)
    end

    # Optional trusted root exposed to skills for resource lookup.
    def skill_resource_root = configuration_values[:skill_resource_root]

    # Replaces the trusted skill resource root for new runtimes.
    def skill_resource_root=(value)
      configuration_values[:skill_resource_root] = value
    end

    def settings(root: nil) # :nodoc:
      requested_root = root && canonical_root(root)
      values = configuration_values.dup
      values[:prompt_paths] = Array(values[:prompt_paths]).dup
      values[:skill_paths] = Array(values[:skill_paths]).dup
      values[:instrumentation_subscribers] = Array(values[:instrumentation_subscribers]).dup
      values[:runtime_hooks] = Array(values[:runtime_hooks]).dup
      values[:model_resolver] = model_resolver
      values[:default_model] = values[:model_resolver].default_model
      values[:root] = requested_root || values[:root] || self.root
      values
    end

    def load_file!(root: nil) # :nodoc:
      requested_root = canonical_root(root || self.root)
      FILE_LOAD_MUTEX.synchronize do
        (@configuration_file_mutex ||= Mutex.new).synchronize do
          if @configuration_file_root
            return self if @configuration_file_root == requested_root

            raise ConfigurationError, "configuration file is already loaded for #{@configuration_file_root}"
          end

          path = File.join(requested_root, "config/little_ghost.rb")
          LittleGhost.with_configuration(self) { Kernel.load(path) } if File.file?(path)
          @configuration_file_root = requested_root
        end
      end

      self
    end

    private

    attr_reader :configuration_values

    def validate_model_resolver_class!(value)
      return if value.is_a?(Class) && value <= ModelResolver

      raise ArgumentError, "model_resolver must be a LittleGhost::ModelResolver subclass"
    end

    def configuration_path(key, filename, value)
      if value != :__read__
        configuration_values[key] = value
        reset_model_resolver
        return value
      end

      configuration_values.fetch(key) { root.join("config/little_ghost", filename) }
    end

    def resolved_providers
      return unless configuration_values.key?(:providers) || (path = resolved_configuration_file(:providers_path, "providers.yml"))

      configured = configuration_values[:providers]
      return configured if configured.is_a?(Providers::Configuration)
      return Providers::Configuration.new(configured) if configuration_values.key?(:providers)

      Models::Configuration.providers(path)
    end

    def resolved_models
      return [configuration_values[:models], nil] if configuration_values.key?(:models)

      path = resolved_configuration_file(:models_path, "models.yml")
      path ? Models::Configuration.models(path) : [nil, nil]
    end

    def resolved_configuration_file(key, filename)
      explicit = configuration_values.key?(key)
      path = Pathname(configuration_values.fetch(key) { root.join("config/little_ghost", filename) })
      path = root.join(path) unless path.absolute?
      return path if path.file?
      raise ConfigurationError, "LittleGhost configuration file does not exist: #{path}" if explicit
    end

    def warn_ignored_model_configuration
      ignored = %i[models models_path default_model].select { |key| configuration_values.key?(key) }
      return if ignored.empty? || @warned_model_resolver_conflict

      Kernel.warn("LittleGhost custom model_resolver ignores configured #{ignored.join(", ")}")
      @warned_model_resolver_conflict = true
    end

    def reset_model_resolver
      @resolved_model_resolver = nil
    end

    def component_class(value, base_class, name)
      unless value.is_a?(Class) && value <= base_class
        raise ArgumentError, "#{name} must be a #{base_class} class"
      end

      value
    end

    def inferred_root
      canonical_root(Dir.pwd)
    end

    def canonical_root(value)
      path = Pathname.new(File.realpath(File.expand_path(value)))
      raise ConfigurationError, "application root must be a directory" unless path.directory?

      path
    rescue Errno::ENOENT
      raise ConfigurationError, "application root must exist"
    end
  end
end
