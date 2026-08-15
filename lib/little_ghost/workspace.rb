# frozen_string_literal: true

require "pathname"

module LittleGhost
  # A Workspace names the host paths associated with a Run. Pair it with a
  # Sandbox to decide how those paths may be read, changed, or used by commands.
  #
  #   workspace = LittleGhost::Workspace.new(root: "./tmp/support-run")
  #   workspace.root # => an absolute path ending in "/tmp/support-run"
  #
  # Workspaces participate in the Run resource lifecycle, but object lifetime
  # and file lifetime are separate. Workspace does not create +root+ or delete
  # it by default. Named paths and setup and teardown callbacks let trusted
  # application configuration provision run-scoped resources without a
  # Workspace subclass. Applications that share a writable root between Runs
  # must provide their own concurrency and tenant isolation.
  class Workspace
    @providers = {}

    class << self
      # Registers a trusted workspace provider under a configuration symbol.
      def register_provider(name, implementation)
        unless implementation.is_a?(Class) && implementation <= Workspace
          raise ArgumentError, "workspace provider must be a Workspace class"
        end

        Workspace.providers[name.to_sym] = implementation
      end

      # Resolves an explicitly selected provider without changing its meaning.
      def resolve_provider(name)
        Workspace.providers.fetch(name.to_sym) do
          raise DependencyError, "workspace provider :#{name} is not available"
        end
      end

      def providers # :nodoc:
        @providers ||= {}
      end
    end

    # Expands +root+ and every named path to absolute paths. Relative named paths
    # must remain beneath +root+; absolute named paths deliberately refer outside
    # it. +setup+ receives +workspace:+ and +run:+ when the Run opens. +teardown+
    # receives the same values when it closes, including after partial setup.
    def initialize(root:, paths: {}, setup: nil, teardown: nil)
      @root = File.expand_path(root)
      @paths = normalize_paths(paths)
      @setup = validate_callback(setup, :setup)
      @teardown = validate_callback(teardown, :teardown)
      @opened = false
      @active = false
      @run = nil
    end

    # Absolute filesystem root assigned to this workspace.
    attr_reader :root

    # Immutable named absolute paths owned by this workspace declaration.
    attr_reader :paths

    # Returns a configured named path, raising KeyError when it is absent.
    def path(name)
      paths.fetch(name.to_sym)
    end

    # Calls the application setup callback once and returns this workspace.
    def open(run: nil)
      return self if @opened

      @run = run
      @active = true
      @setup&.call(workspace: self, run:)
      @opened = true
      self
    rescue
      close
      raise
    end

    # Calls the application teardown callback once. The default does not remove
    # files or directories.
    def close
      return nil unless @active

      @teardown&.call(workspace: self, run: @run)
      nil
    ensure
      @opened = false
      @active = false
      @run = nil
    end

    private

    def normalize_paths(values)
      unless values.respond_to?(:each_pair)
        raise ArgumentError, "workspace paths must be a Hash"
      end

      values.each_pair.to_h do |name, value|
        key = name.to_sym
        path = value.to_s
        raise ArgumentError, "workspace path :#{key} must not be empty" if path.empty?

        expanded = File.expand_path(path, root)
        root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        if !Pathname.new(path).absolute? && expanded != root && !expanded.start_with?(root_prefix)
          raise ArgumentError, "relative workspace path :#{key} must remain beneath the workspace root"
        end

        [key, expanded.freeze]
      end.freeze
    end

    def validate_callback(callback, name)
      return unless callback
      raise ArgumentError, "workspace #{name} must be callable" unless callback.respond_to?(:call)

      callback
    end
  end

  Workspace.register_provider(:directory, Workspace)
end
