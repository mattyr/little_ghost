# frozen_string_literal: true

require "pathname"

module LittleGhost
  # A Workspace gives an agent a concrete home for files. Pair it with a Sandbox
  # to decide how those files may be read, changed, or used by commands.
  #
  #   workspace = LittleGhost::Workspace.new(root: "./tmp/support-run")
  #   workspace.root # => an absolute path ending in "/tmp/support-run"
  #
  # Workspaces participate in the run resource lifecycle. Named paths let an
  # application expose workspace-owned directories to sandbox configuration,
  # while setup and teardown callbacks provision run-scoped resources without a
  # Workspace subclass.
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
    # are resolved beneath +root+. +setup+ receives +workspace:+ and +run:+ when
    # the run opens; +teardown+ receives the same values when it closes.
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

    # Opens any run-scoped resources and yields this workspace to the run.
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

    # Releases workspace resources. The default workspace has nothing to close.
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
        if !Pathname.new(path).absolute? && expanded != root && !expanded.start_with?("#{root}#{File::SEPARATOR}")
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
