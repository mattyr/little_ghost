# frozen_string_literal: true

require "pathname"
require "monitor"
require_relative "skills/resource_root"

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
  # Configuration is a mutable application builder until its shared Runtime is
  # first used. A successful #runtime call locks the builder so standalone
  # Agents and Assemblies keep one stable setup. Configure the application
  # before its first entrypoint call. Explicit Runtime construction remains an
  # advanced way to take an independent snapshot without selecting the shared
  # default.
  #
  # Multi-tenant applications should derive Session actor identity from state
  # established after authentication, not from an unverified request field.
  class Configuration
    FILE_LOAD_MUTEX = Mutex.new # :nodoc:
    CONFIGURATION_KEYS = %i[invocation service_name].freeze # :nodoc:
    RUNTIME_BUILD_CONTEXT_KEY = :little_ghost_runtime_build_context # :nodoc:
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

        change_configuration { configuration_values[name] = value }
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
      @lifecycle_monitor = Monitor.new
      @runtime_condition = @lifecycle_monitor.new_cond
      @configuration_values = {
        prompt_paths: DEFAULT_PROMPT_PATHS.dup,
        skill_paths: DEFAULT_SKILL_PATHS.dup,
        skill_resource_root: nil,
        workspace: nil,
        sandbox: nil,
        code_mode: nil,
        instrumentation_subscribers: [],
        runtime_hooks: [],
        concurrency_backend: :auto
      }.merge(values)
      @configuration_values[:concurrency_backend] = normalize_concurrency_backend(
        @configuration_values[:concurrency_backend]
      )
      @configuration_values[:prompt_paths] = Array(@configuration_values[:prompt_paths]).dup
      @configuration_values[:skill_paths] = Array(@configuration_values[:skill_paths]).dup
      @configuration_values[:skill_resource_root] = Skills::ResourceRoot.normalize(
        @configuration_values[:skill_resource_root]
      )
      @configuration_values[:instrumentation_subscribers] = Array(
        @configuration_values[:instrumentation_subscribers]
      ).dup
      @configuration_values[:runtime_hooks] = Array(@configuration_values[:runtime_hooks]).dup
      @configuration_values[:provider_adapters] = @configuration_values.fetch(:provider_adapters, {}).dup
      @configuration_values[:catalog_sources] = Array(@configuration_values[:catalog_sources]).dup
      @configuration_values[:provider_credentials] ||= nil
      if @configuration_values[:workspace]
        @configuration_values[:workspace] = component_declaration(
          @configuration_values[:workspace], Workspace, :workspace
        )
      end
      if @configuration_values[:sandbox]
        @configuration_values[:sandbox] = component_declaration(
          @configuration_values[:sandbox], Sandbox, :sandbox
        )
      end
    end

    # Yields this builder for setup and returns the same instance.
    def configure
      change_configuration { yield self } if block_given?
      self
    end

    # Returns the shared Runtime for this configuration, building it on first
    # use. Once construction succeeds, the configuration is locked so every
    # standalone entrypoint continues to use one stable application setup. The
    # conventional configuration file may finish loading during construction;
    # other writes are rejected. A failed build leaves the configuration
    # editable for a later attempt.
    def runtime
      build_generation, build_context = @lifecycle_monitor.synchronize do
        loop do
          return @default_runtime if @default_runtime
          if @runtime_building
            if current_runtime_build_context.equal?(@runtime_build_context)
              raise ConfigurationError, "LittleGhost.runtime cannot be called while the shared Runtime is starting"
            end

            waiting_generation = @runtime_generation
            @runtime_condition.wait
            return @default_runtime if @default_runtime
            if @runtime_failure_generation == waiting_generation
              raise @runtime_failure
            end
          else
            sealed_values = freeze_configuration_copy(@configuration_values)
            @runtime_generation = @runtime_generation.to_i + 1
            @runtime_building = true
            @runtime_build_context = Object.new
            @configuration_values = sealed_values
            break [@runtime_generation, @runtime_build_context]
          end
        end
      end

      ExecutionState.with(RUNTIME_BUILD_CONTEXT_KEY => build_context) do
        runtime_root = root
        load_file!(root: runtime_root)
        runtime_settings = settings(root: runtime_root)
        built = Runtime.new(configuration: self, settings: runtime_settings)
        @lifecycle_monitor.synchronize do
          configuration_values.freeze
          @default_runtime = built
        end
        built
      rescue => error
        editable_values = if @configuration_values.frozen?
          copy_configuration_value(@configuration_values)
        else
          @configuration_values
        end
        @lifecycle_monitor.synchronize do
          @configuration_values = editable_values
          @runtime_failure = error
          @runtime_failure_generation = build_generation
        end
        raise
      ensure
        @lifecycle_monitor.synchronize do
          @runtime_building = false
          @runtime_build_context = nil
          @runtime_condition.broadcast
        end
      end
    end

    # Selects how subsequently built runtimes start independent work such as
    # parallel Tool calls and Workflow branches.
    #
    # The default, +:auto+, uses scheduler-owned fibers when work starts inside
    # a fiber managed by the active scheduler, and threads otherwise. +:thread+
    # always uses threads. +:fiber+ requires an active scheduler-managed fiber
    # and raises ConfigurationError when work cannot be scheduled. Any other
    # value raises ArgumentError.
    #
    #   LittleGhost.configure do |config|
    #     config.concurrency_backend = :thread
    #   end
    #
    # :call-seq:
    #   concurrency_backend() -> :auto, :thread, :fiber
    #   concurrency_backend(value) -> :auto, :thread, :fiber
    def concurrency_backend(value = :__read__)
      return configuration_values[:concurrency_backend] if value == :__read__

      normalized = normalize_concurrency_backend(value)
      change_configuration { configuration_values[:concurrency_backend] = normalized }
      normalized
    end

    # Replaces the concurrency backend for subsequently built runtimes.
    def concurrency_backend=(value)
      concurrency_backend(value)
    end

    # Workspace declaration used for subsequently built runtimes.
    def workspace = configuration_values[:workspace]
    # Sandbox declaration used for subsequently built runtimes.
    def sandbox = configuration_values[:sandbox]
    # Default code-mode declaration for enabled Agents. The Hash may select an
    # +:engine+ and +:sandbox+, override +:limits+, and name Tools to keep in the
    # conversation with +:except+.
    def code_mode = configuration_values[:code_mode]
    # Session-store declaration used for subsequently built runtimes.
    def session_store = configuration_values[:session_store]

    # Trusted provider connections for the default or custom resolver.
    def providers(value = :__read__)
      return configuration_values[:providers] if value == :__read__

      ensure_configuration_open!
      unless value.is_a?(Hash) || value.is_a?(Providers::Configuration)
        raise ArgumentError, "providers must be a Hash or LittleGhost::Providers::Configuration"
      end

      change_configuration do
        configuration_values[:providers] = value
        reset_model_resolver
      end
      value
    end

    # Replaces trusted provider connections for subsequently built runtimes.
    def providers=(value)
      providers(value)
    end

    # Logical model profiles for the default resolver. Role names cannot contain
    # a colon because that syntax identifies a canonical model target.
    def models(value = :__read__)
      return configuration_values[:models] if value == :__read__
      ensure_configuration_open!
      raise ArgumentError, "models must be a Hash" unless value.is_a?(Hash)

      change_configuration do
        configuration_values[:models] = value
        reset_model_resolver
      end
      value
    end

    # Replaces logical model profiles for subsequently built runtimes.
    def models=(value)
      models(value)
    end

    # Fallback logical role for the default resolver.
    def default_model(value = :__read__)
      return configuration_values[:default_model] if value == :__read__

      change_configuration do
        configuration_values[:default_model] = value.to_s
        reset_model_resolver
      end
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
        ensure_configuration_open!
        validate_model_resolver_class!(value)

        change_configuration do
          configuration_values[:model_resolver] = value
          @resolved_model_resolver = nil
        end
        return value
      end

      @model_resolver_mutex ||= Mutex.new
      @model_resolver_mutex.synchronize do
        @resolved_model_resolver ||= begin
          providers = resolved_providers
          credential_resolver = configuration_values[:provider_credentials] || providers&.method(:credentials)
          configured = configuration_values[:model_resolver]
          if configured
            validate_model_resolver_configuration!
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
      ensure_configuration_open!
      implementation = factory || callable
      if implementation.is_a?(Class)
        unless implementation <= Providers::Base
          raise ArgumentError, "provider adapter class must inherit LittleGhost::Providers::Base"
        end
      elsif !implementation.respond_to?(:call)
        raise ArgumentError, "provider adapter must be a Providers::Base class or callable factory"
      end

      change_configuration do
        configuration_values[:provider_adapters][name.to_s] = implementation
        @resolved_model_resolver = nil
      end
      implementation
    end

    # Adds an explicit catalog source. Sources refresh only when callers invoke
    # ModelResolver#refresh!.
    def catalog_source(source)
      ensure_configuration_open!
      raise ArgumentError, "catalog source must be a Models::Catalog::Source" unless source.is_a?(Models::Catalog::Source)

      change_configuration do
        configuration_values[:catalog_sources] << source
        @resolved_model_resolver = nil
      end
      source
    end

    # Installs a trusted callable that returns credential options for a named
    # provider connection when each executable model is constructed.
    def provider_credentials(callable = nil, &resolver)
      value = resolver || callable
      return configuration_values[:provider_credentials] unless value
      ensure_configuration_open!
      raise ArgumentError, "provider credential resolver must be callable" unless value.respond_to?(:call)

      change_configuration do
        configuration_values[:provider_credentials] = value
        @resolved_model_resolver = nil
      end
      value
    end

    # Selects the Workspace provider instantiated for each run. A declaration
    # may be a registered provider symbol, callable, or a Hash containing a
    # +:provider+ and constructor options.
    def workspace=(value)
      change_configuration do
        @configuration_values[:workspace] = component_declaration(value, Workspace, :workspace)
      end
    end

    # Selects the Sandbox provider instantiated around each run's workspace.
    # LittleGhost does not fall back to unrestricted execution when an explicit
    # backend is unavailable.
    def sandbox=(value)
      change_configuration do
        @configuration_values[:sandbox] = component_declaration(value, Sandbox, :sandbox)
      end
    end

    # Configures application defaults for code-mode Agents. The Hash may select
    # an +:engine+ and +:sandbox+, override +:limits+, and name ordinary Tools
    # that remain in the conversation with +:except+.
    def code_mode=(value)
      change_configuration do
        raise ArgumentError, "code_mode must be a Hash" unless value.nil? || value.is_a?(Hash)

        @configuration_values[:code_mode] = value&.transform_keys(&:to_sym)&.freeze
      end
    end

    # Selects session persistence with a +:provider+ and its constructor options.
    #
    # The provider must be a SessionStore subclass. Runtime construction creates
    # and owns the store instance.
    def session_store=(value)
      ensure_configuration_open!
      unless value.is_a?(Hash)
        raise ArgumentError, "session_store must be a hash with a provider"
      end

      provider = value[:provider]
      change_configuration do
        @configuration_values[:session_store] = value.merge(
          provider: component_class(provider, SessionStore, :session_store)
        )
      end
    end

    # Looks up an arbitrary setting by symbol or string-compatible name.
    def [](name)
      configuration_values.fetch(name.to_sym)
    end

    # Adds or replaces an arbitrary setting.
    def []=(name, value)
      case name.to_sym
      when :workspace
        self.workspace = value
      when :sandbox
        self.sandbox = value
      when :code_mode
        self.code_mode = value
      when :concurrency_backend
        self.concurrency_backend = value
      else
        change_configuration { configuration_values[name.to_sym] = value }
      end
    end

    # Replaces the application root after resolving it to a stable real path.
    def root=(value)
      root(value)
    end

    # Adds an Instrumentation::Subscriber to each new runtime and returns it.
    def instrument(subscriber)
      ensure_configuration_open!
      unless subscriber.is_a?(Instrumentation::Subscriber)
        raise ArgumentError, "instrumentation subscriber must be a LittleGhost::Instrumentation::Subscriber"
      end

      change_configuration { configuration_values[:instrumentation_subscribers] << subscriber }
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

      change_configuration { Events.console_output = destination }
    end

    # Replaces the console destination for structured framework events.
    def log_events_to=(destination)
      log_events_to(destination)
    end

    # Adds a Runtime::Hook subclass to each new runtime and returns it.
    def runtime_hook(hook_class)
      ensure_configuration_open!
      unless hook_class.is_a?(Class) && hook_class <= Runtime::Hook
        raise ArgumentError, "runtime_hook must be a LittleGhost::Runtime::Hook class"
      end

      change_configuration { configuration_values[:runtime_hooks] << hook_class }
      hook_class
    end

    # Stores input attachments, Tool artifacts, and oversized successful Tool
    # values under the conventional +:artifacts+ Workspace path. An optional
    # block receives deferred Artifacts and may load their bytes for the current
    # Run. It may return a String, an inline Artifact, or nil.
    #
    # The block is application code. It must authorize each reference using
    # identity established by the application and limit any file or network read
    # before returning bytes. LittleGhost applies its storage limits afterward.
    #
    # :call-seq:
    #   artifacts() -> Class<Runtime::Hook>
    #   artifacts { |artifact, run:| bytes_or_artifact_or_nil } -> Class<Runtime::Hook>
    def artifacts(&resolver)
      hook = Runtime::Hooks::Artifacts.configured(resolver:)
      ensure_configuration_open!
      change_configuration do
        configuration_values[:runtime_hooks].reject! do |configured|
          configured <= Runtime::Hooks::Artifacts
        end
        configuration_values[:runtime_hooks] << hook
      end
      hook
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

      ensure_configuration_open!
      raise ArgumentError, "Provide a session actor resolver or a block, not both" if value != :__read__ && resolver

      configured = resolver || value
      raise ArgumentError, "session_actor must be callable" unless configured.respond_to?(:call)

      change_configuration { configuration_values[:session_actor] = configured }
    end

    # :call-seq:
    #   root() -> Pathname
    #   root(path) -> Pathname
    #
    # The resolved application root, defaulting to +Dir.pwd+.
    #
    # Setting or reading an invalid root raises ConfigurationError. Symlinks are
    # resolved so runtimes and lookup paths use the same canonical directory.
    def root(value = :__read__)
      if value != :__read__
        return change_configuration { configuration_values[:root] = canonical_root(value) }
      end

      configured = configuration_values[:root]
      configured ? canonical_root(configured) : inferred_root
    end

    # Prompt lookup paths in precedence order. The Array is mutable until the
    # shared Runtime is built.
    def prompt_paths = configuration_values[:prompt_paths]

    # Replaces prompt lookup paths with +value+ converted to an Array.
    def prompt_paths=(value)
      change_configuration { configuration_values[:prompt_paths] = Array(value) }
    end

    # Skill lookup paths in precedence order. The Array is mutable until the
    # shared Runtime is built.
    def skill_paths = configuration_values[:skill_paths]

    # Replaces skill lookup paths with +value+ converted to an Array.
    def skill_paths=(value)
      change_configuration { configuration_values[:skill_paths] = Array(value) }
    end

    # Optional model-facing root used for skill locations and resources. The
    # value may be an absolute process-visible path. A
    # <tt>workspace://name</tt> reference must map to the configured skill path
    # through a read-only file grant in each Run's Workspace and Sandbox. The
    # application must not expose the same files through another writable bind
    # mount.
    def skill_resource_root = configuration_values[:skill_resource_root]

    # Replaces and validates the skill resource root for new runtimes.
    def skill_resource_root=(value)
      change_configuration do
        configuration_values[:skill_resource_root] = Skills::ResourceRoot.normalize(value)
      end
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
          load_configuration_file(path) if File.file?(path)
          @configuration_file_root = requested_root
        end
      end

      self
    end

    private

    def configuration_values
      @lifecycle_monitor.synchronize do
        if @runtime_building && !current_runtime_build_context.equal?(@runtime_build_context)
          raise_locked_configuration!
        end

        @configuration_values
      end
    end

    def validate_model_resolver_class!(value)
      return if value.is_a?(Class) && value <= ModelResolver

      raise ArgumentError, "model_resolver must be a LittleGhost::ModelResolver subclass"
    end

    def configuration_path(key, filename, value)
      if value != :__read__
        change_configuration do
          configuration_values[key] = value
          reset_model_resolver
        end
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

    def validate_model_resolver_configuration!
      conflicting = %i[models models_path default_model].select { |key| configuration_values.key?(key) }
      return if conflicting.empty?

      raise ConfigurationError,
        "custom model_resolver cannot be combined with #{conflicting.join(", ")}"
    end

    def reset_model_resolver
      @resolved_model_resolver = nil
    end

    def change_configuration
      @lifecycle_monitor.synchronize do
        raise_locked_configuration! unless configuration_changes_allowed?

        yield
      end
    end

    def ensure_configuration_open!
      @lifecycle_monitor.synchronize do
        raise_locked_configuration! unless configuration_changes_allowed?
      end
    end

    def raise_locked_configuration!
      raise ConfigurationError,
        "LittleGhost configuration is locked while its shared Runtime is starting or after it is ready; configure the application before its first Agent or Assembly call"
    end

    def configuration_changes_allowed?
      return false if @default_runtime
      return true unless @runtime_building

      @configuration_file_loading && current_runtime_build_context.equal?(@runtime_build_context)
    end

    def current_runtime_build_context
      ExecutionState[RUNTIME_BUILD_CONTEXT_KEY]
    end

    def normalize_concurrency_backend(value)
      normalized = value.to_sym if value.respond_to?(:to_sym)
      return normalized if Support::TaskRunner::BACKENDS.include?(normalized)

      raise ArgumentError, "concurrency_backend must be :auto, :thread, or :fiber"
    end

    def load_configuration_file(path)
      editable_values = copy_configuration_value(@configuration_values)
      @lifecycle_monitor.synchronize do
        @configuration_values = editable_values
        @configuration_file_loading = true
      end
      LittleGhost.with_configuration(self) { Kernel.load(path) }
    ensure
      sealed_values = freeze_configuration_copy(@configuration_values)
      @lifecycle_monitor.synchronize do
        @configuration_values = sealed_values
        @configuration_file_loading = false
      end
    end

    def freeze_configuration_copy(value)
      opaque_values = {}
      copied = copy_configuration_value(value, {}, opaque_values)
      freeze_configuration_value(copied, opaque_values)
    end

    def copy_configuration_value(value, ancestors = {}, opaque_values = {})
      if value.is_a?(Hash) || value.is_a?(Array)
        identity = value.object_id
        raise ArgumentError, "cyclic values cannot be duplicated" if ancestors.key?(identity)

        ancestors[identity] = true
      end
      case value
      when Hash
        supported_keys = true
        Hash.instance_method(:each_key).bind_call(value) do |key|
          supported_keys &&= configuration_declaration_key?(key)
        end
        unless supported_keys
          opaque_values[value.object_id] = true
          return value
        end
        copy = {}
        Hash.instance_method(:each_pair).bind_call(value) do |key, child|
          copy[copy_configuration_value(key, ancestors, opaque_values)] =
            copy_configuration_value(child, ancestors, opaque_values)
        end
        copy
      when Array
        copy = []
        Array.instance_method(:each).bind_call(value) do |child|
          copy << copy_configuration_value(child, ancestors, opaque_values)
        end
        copy
      when String
        String.new(value)
      else
        value
      end
    ensure
      ancestors.delete(identity) if identity
    end

    def configuration_declaration_key?(key)
      key.instance_of?(String) ||
        key.instance_of?(Symbol) ||
        key.instance_of?(Integer) ||
        key.instance_of?(Float) ||
        key.instance_of?(Rational) ||
        key.instance_of?(Complex) ||
        key.nil? ||
        key.equal?(true) ||
        key.equal?(false)
    end

    def freeze_configuration_value(value, opaque_values = {})
      return value if opaque_values.key?(value.object_id)

      case value
      when Hash
        value.each do |key, child|
          freeze_configuration_value(key, opaque_values)
          freeze_configuration_value(child, opaque_values)
        end
      when Array
        value.each { |child| freeze_configuration_value(child, opaque_values) }
      end
      value.freeze if value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(String)
      value
    end

    def component_class(value, base_class, name)
      unless value.is_a?(Class) && value <= base_class
        raise ArgumentError, "#{name} must be a #{base_class} class"
      end

      value
    end

    def component_declaration(value, base_class, name)
      return value if value.is_a?(Symbol) || callable_component?(value)

      unless value.is_a?(Hash)
        raise ArgumentError, "#{name} must be a provider symbol, callable, or Hash"
      end

      declaration = value.transform_keys(&:to_sym)
      raise ArgumentError, "#{name} must include a provider" unless declaration.key?(:provider)

      provider = declaration[:provider]
      valid_class = provider.is_a?(Class) && provider <= base_class
      unless provider.is_a?(Symbol) || callable_component?(provider) || valid_class
        raise ArgumentError, "#{name} provider must be a #{base_class} class, symbol, or callable"
      end
      declaration
    end

    def callable_component?(value)
      value.respond_to?(:call) && !value.is_a?(Class)
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
