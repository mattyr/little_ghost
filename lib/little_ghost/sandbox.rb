# frozen_string_literal: true

module LittleGhost
  # A Sandbox governs filesystem operations and child processes that explicitly
  # pass through it. Built-in filesystem and shell Tools use their bound
  # Sandbox. A custom Ruby Tool remains trusted application code unless it
  # delegates work to that Sandbox or one of its Scopes.
  #
  #   LittleGhost.configure do |config|
  #     config.sandbox = {
  #       provider: :native,
  #       files: {root: :read_write, source: :read_only},
  #       runtime_paths: {home: :read_write},
  #       network: :none
  #     }
  #   end
  #
  # Implementations report their effective policy and capabilities, confine
  # brokered paths to declared Workspace paths, honor RunContext cancellation, enforce
  # time and output limits, and return
  # {Execution}[rdoc-ref:LittleGhost::Sandbox::Execution] from process
  # operations. A backend's isolation mechanism still relies on its outer host,
  # kernel or VM, dependencies, trusted configuration, and deliberately exposed
  # paths. Sandbox policy does not apply to provider requests or arbitrary Ruby
  # code in the application process.
  class Sandbox
    @providers = {}

    class << self
      # Registers a trusted backend class under a configuration symbol.
      def register_provider(name, implementation)
        unless implementation.is_a?(Class) && implementation <= Sandbox
          raise ArgumentError, "sandbox provider must be a Sandbox class"
        end

        Sandbox.providers[name.to_sym] = implementation
      end

      # Resolves a registered backend without silently falling back.
      def resolve_provider(name)
        Sandbox.providers.fetch(name.to_sym) do
          raise DependencyError, "sandbox provider :#{name} is not available"
        end
      end

      # Reports whether a registered backend can start in the current
      # environment without creating a Run-owned sandbox.
      def probe(name, **options)
        implementation = resolve_provider(name)
        provider_probe = implementation.method(:probe)
        return provider_probe.call(**options) unless provider_probe.owner == Sandbox.singleton_class
        unless options.empty?
          raise ArgumentError, "sandbox provider :#{name} does not accept probe options"
        end

        {
          available: true,
          reason: nil,
          capabilities: Capabilities.new(features: [], network_modes: [])
        }
      rescue DependencyError => error
        {available: false, reason: error.message, capabilities: Capabilities.new(features: [], network_modes: [])}
      end

      def providers # :nodoc:
        @providers ||= {}
      end
    end

    # Contains captured process output, exit status, and an optional execution
    # error.
    Execution = Data.define(:stdout, :stderr, :exit_code, :error) do # :nodoc:
      def initialize(stdout:, stderr:, exit_code:, error: nil)
        super
      end

      def success?
        error.nil? && exit_code&.zero?
      end
    end

    # Carries captured process output, exit status, and an optional execution
    # error from Sandbox#execute or Sandbox#execute_program.
    class Execution < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(stdout:, stderr:, exit_code:, error: nil) -> Execution
      #
      # Collects the observable result of one sandbox process.

      ##
      # :attr_reader: stdout
      # Captured standard output, subject to the sandbox's output limit.

      ##
      # :attr_reader: stderr
      # Captured standard error, subject to the sandbox's output limit.

      ##
      # :attr_reader: exit_code
      # The child process exit status, when one is available.

      ##
      # :attr_reader: error
      # The execution error, or +nil+ when the process completed normally.

      ##
      # :method: success?
      # Indicates that no execution error occurred and the exit code is zero.
    end

    # Binds the sandbox to +workspace+.
    def initialize(workspace:, policy: nil, profiles: {}, limits: {})
      @workspace = workspace
      @policy = Policy.coerce(policy)
      @limits = Limits.coerce(limits)
      configure_profiles!(profiles)
    end

    # Workspace whose files and processes this sandbox governs.
    attr_reader :workspace

    # Normalized policy requested by trusted application configuration.
    attr_reader :policy
    # File and process output bounds enforced by this Sandbox.
    attr_reader :limits

    # Policy the backend enforces. Backends may fill a documented default or
    # report an unavoidable effective value, but reject unsupported requested
    # rules instead of silently claiming enforcement.
    def effective_policy = policy

    # Operations and network modes implemented by this backend.
    def capabilities
      Capabilities.new(features: [], network_modes: [])
    end

    # Indicates whether the backend implements +feature+.
    def supports?(feature, value = nil) = capabilities.supports?(feature, value)

    # Indicates whether an operation is allowed by this sandbox and optional
    # virtual +path+.
    def allows?(operation, path = nil)
      return supports?(operation) unless path

      scope.allows?(operation, path)
    end

    # Produces a non-owning capability-reduced view for tools or child agents.
    # The caller must pass and use that Scope; retaining this parent Sandbox
    # retains its broader authority.
    def scope(profile = nil, files: nil, runtime_paths: nil, capabilities: nil, network: nil)
      if profile
        if !files.nil? || !runtime_paths.nil? || !capabilities.nil? || !network.nil?
          raise ArgumentError, "scope profile cannot be combined with explicit options"
        end

        declaration = @profiles.fetch(profile.to_sym) do
          raise PolicyError, "unknown sandbox scope profile: #{profile.inspect}"
        end
        declaration = declaration.call(workspace:, policy: effective_policy) if declaration.respond_to?(:call)
        unless declaration.respond_to?(:transform_keys)
          raise PolicyError, "sandbox scope profile must be a Hash"
        end
        values = declaration.transform_keys(&:to_sym)
        unknown = values.keys - %i[files runtime_paths capabilities network]
        raise PolicyError, "unknown sandbox scope profile options: #{unknown.join(", ")}" unless unknown.empty?
        files = values[:files]
        runtime_paths = values[:runtime_paths]
        capabilities = values[:capabilities]
        network = values[:network]
      end
      Scope.new(sandbox: self, files:, runtime_paths:, capabilities:, network:)
    end

    # Opens any run-scoped resources and makes the sandbox ready for tools.
    def open(run: nil)
      self
    end

    # Indicates whether filesystem mutation is allowed.
    def writable? = supports?(:filesystem_write)

    # Reads UTF-8 text at a workspace-relative or absolute virtual +path+.
    def read(path, context: nil)
      raise AbstractMethodError, "#{self.class} does not support filesystem reads"
    end

    # Lists entries at a workspace-relative or absolute virtual directory +path+.
    def list(path = ".", context: nil)
      raise AbstractMethodError, "#{self.class} does not support filesystem listings"
    end

    # Writes +content+ to a workspace-relative or absolute virtual +path+.
    def write(path, content, context: nil)
      raise AbstractMethodError, "#{self.class} does not support filesystem writes"
    end

    # Replaces one exact +old_text+ occurrence at a workspace-relative or
    # absolute virtual +path+ with +new_text+.
    def replace(path, old_text, new_text, context: nil)
      raise AbstractMethodError, "#{self.class} does not support filesystem edits"
    end

    # Executes +command+ through +/bin/sh+.
    #
    # Prefer #execute_program for model-controlled arguments so shell syntax is
    # not interpreted.
    def execute(command, timeout:, context: nil, max_output_bytes: nil, **options)
      execute_program(
        ["/bin/sh", "-c", String(command)],
        timeout:,
        context:,
        max_output_bytes:,
        **options
      )
    end

    # Executes an argument vector without shell interpretation.
    #
    # Implementations must enforce +timeout+ and +max_output_bytes+. Environment
    # inheritance is disabled by default to avoid leaking process credentials;
    # both policy and the individual call must opt in before a backend may inherit.
    def execute_program(command, timeout:, context: nil, max_output_bytes: nil, environment: {}, inherit_environment: false, **options)
      raise AbstractMethodError, "#{self.class} does not support program execution"
    end

    # Starts an owned, duplex child process for framed protocols and other
    # interactive programs. The returned session owns the child process group.
    def start_program(command, context: nil, environment: {}, inherit_environment: false, **options)
      raise AbstractMethodError, "#{self.class} does not support program sessions"
    end

    # Releases sandbox resources. Runs close the sandbox before its workspace.
    def close
      nil
    end

    private

    def configure_profiles!(profiles)
      unless profiles.respond_to?(:to_h)
        raise PolicyError, "sandbox profiles must be a Hash"
      end

      @profiles = profiles.to_h.transform_keys(&:to_sym).freeze
    end
  end
end

require_relative "sandbox/capabilities"
require_relative "sandbox/limits"
require_relative "sandbox/mount"
require_relative "sandbox/environment_policy"
require_relative "sandbox/network_policy"
require_relative "sandbox/policy"
require_relative "sandbox/filesystem"
require_relative "sandbox/scope"
