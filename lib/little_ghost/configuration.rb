# frozen_string_literal: true

require "pathname"

module LittleGhost
  # Configure shared services and lookup rules before agents start.
  # A configuration collects model profiles, persistence, paths,
  # instrumentation, and runtime hooks for an application.
  #
  #   LittleGhost.configure do |config|
  #     config.models CustomerSupportModels
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
    CONFIGURATION_KEYS = %i[invocation models default_model service_name].freeze # :nodoc:
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
    # The model registry class or instance used to resolve logical roles.
    #
    # :method: models
    # :call-seq:
    #   models() -> value
    #   models(value) -> value

    ##
    # The fallback logical model role for agents without an explicit role.
    # Values are normalized to strings.
    #
    # :method: default_model
    # :call-seq:
    #   default_model() -> String, nil
    #   default_model(value) -> String

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

        configuration_values[name] = (name == :default_model) ? value.to_s : value
      end
    end

    ##
    # Replaces the request envelope class for subsequently built runtimes.
    # :method: invocation=
    # :call-seq:
    #   invocation=(value) -> value

    ##
    # Replaces the model registry declaration for subsequently built runtimes.
    # :method: models=
    # :call-seq:
    #   models=(value) -> value

    ##
    # Replaces the fallback logical model role and normalizes it to a String.
    # :method: default_model=
    # :call-seq:
    #   default_model=(value) -> String

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
