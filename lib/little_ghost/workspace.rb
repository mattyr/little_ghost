# frozen_string_literal: true

require "pathname"
require "fileutils"

module LittleGhost
  # A Workspace names the host paths associated with a Run. Pair it with a
  # Sandbox to decide how those paths may be read, changed, or used by commands.
  #
  #   workspace = LittleGhost::Workspace.new(root: "./tmp/support-run")
  #   workspace.root # => an absolute path ending in "/tmp/support-run"
  #
  # Workspaces participate in the Run resource lifecycle, but object lifetime
  # and file lifetime are separate. Opening creates +root+ and relative named
  # paths, but does not delete them by default. Absolute named paths are trusted
  # references that must already exist. Setup and teardown callbacks let trusted
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
      @identities = nil
    end

    # Absolute filesystem root assigned to this workspace.
    attr_reader :root

    # Immutable named absolute paths owned by this workspace declaration.
    attr_reader :paths

    # Returns a configured named path, raising KeyError when it is absent.
    def path(name)
      paths.fetch(name.to_sym)
    end

    # Resolves a model-safe logical path to its physical workspace path.
    # Relative paths belong to +root+; named paths use
    # <tt>workspace://name/path</tt>. Physical absolute paths are deliberately
    # rejected so brokered tools do not teach callers host filesystem layout.
    def resolve(reference)
      validate! if @identities
      value = String(reference)
      raise ArgumentError, "workspace paths must be relative or use workspace://" if Pathname.new(value).absolute?

      base, relative = if value.start_with?("workspace://")
        logical = value.delete_prefix("workspace://")
        name, separator, child = logical.partition("/")
        raise ArgumentError, "workspace path must name a configured path" if name.empty?

        [path(name), separator.empty? ? "." : child]
      else
        [root, value]
      end
      resolve_beneath(base, relative)
    end

    # Returns the stable logical reference for a physical workspace path.
    def reference(physical_path)
      candidate = File.expand_path(physical_path)
      named = paths.sort_by { |_, path| -path.length }.find { |_, path| beneath?(candidate, path) }
      if named
        name, base = named
        relative = candidate.delete_prefix(base).delete_prefix(File::SEPARATOR)
        return relative.empty? ? "workspace://#{name}" : "workspace://#{name}/#{relative}"
      end
      raise ArgumentError, "path is outside the workspace" unless beneath?(candidate, root)

      candidate.delete_prefix(root).delete_prefix(File::SEPARATOR).then { |value| value.empty? ? "." : value }
    end

    # Environment variables supplied to sandboxed programs. These values are
    # trusted process configuration and are never returned by filesystem tools.
    def environment
      {"LITTLE_GHOST_WORKSPACE_ROOT" => root}.merge(paths.to_h do |name, path|
        ["LITTLE_GHOST_WORKSPACE_#{name.to_s.upcase.gsub(/[^A-Z0-9]/, "_")}", path]
      end).freeze
    end

    # Verifies that no configured directory was replaced after #open.
    def validate!
      return self unless @identities

      {root: root}.merge(paths).each do |name, path|
        realpath = File.realpath(path)
        stat = File.stat(realpath)
        expected = @identities.fetch(name)
        unless [realpath, stat.dev, stat.ino] == expected
          raise ToolError, "workspace path changed after opening: #{name}"
        end
      end
      self
    rescue Errno::ENOENT
      raise ToolError, "workspace path changed after opening: #{name}"
    end

    # Calls the application setup callback once and returns this workspace.
    def open(run: nil)
      return self if @opened

      @run = run
      @active = true
      @setup&.call(workspace: self, run:)
      materialize!
      capture_identities!
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
      @identities = nil
    end

    private

    def materialize!
      FileUtils.mkdir_p(root)
      paths.each do |name, directory|
        if @relative_path_names.include?(name)
          FileUtils.mkdir_p(directory)
        elsif !File.directory?(directory)
          raise ArgumentError, "absolute workspace path :#{name} must already exist"
        end
      end
    end

    def capture_identities!
      entries = {root: root}.merge(paths)
      identities = entries.to_h do |name, path|
        realpath = File.realpath(path)
        stat = File.stat(realpath)
        [name, [realpath, stat.dev, stat.ino].freeze]
      end
      duplicates = identities.group_by { |_, identity| identity.drop(1) }.select { |_, values| values.length > 1 }
      unless duplicates.empty?
        names = duplicates.values.flat_map { |values| values.map(&:first) }
        raise ArgumentError, "workspace paths must not alias the same directory: #{names.join(", ")}"
      end
      @identities = identities.freeze
    end

    def resolve_beneath(base, relative)
      raise ArgumentError, "workspace path must not be empty" if relative.empty?
      components = Pathname.new(relative).each_filename.to_a
      raise ArgumentError, "workspace path traversal is not allowed" if components.include?("..")

      expanded = File.expand_path(relative, base)
      raise ArgumentError, "workspace path escapes its root" unless beneath?(expanded, base)

      expanded
    end

    def beneath?(candidate, base)
      candidate == base || candidate.start_with?(base.end_with?(File::SEPARATOR) ? base : "#{base}#{File::SEPARATOR}")
    end

    def normalize_paths(values)
      unless values.respond_to?(:each_pair)
        raise ArgumentError, "workspace paths must be a Hash"
      end

      relative_names = []
      normalized = values.each_pair.to_h do |name, value|
        key = name.to_sym
        path = value.to_s
        raise ArgumentError, "workspace path :#{key} must not be empty" if path.empty?

        expanded = File.expand_path(path, root)
        root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        relative = !Pathname.new(path).absolute?
        if relative && expanded != root && !expanded.start_with?(root_prefix)
          raise ArgumentError, "relative workspace path :#{key} must remain beneath the workspace root"
        end
        relative_names << key if relative

        [key, expanded.freeze]
      end.freeze
      @relative_path_names = relative_names.freeze
      normalized
    end

    def validate_callback(callback, name)
      return unless callback
      raise ArgumentError, "workspace #{name} must be callable" unless callback.respond_to?(:call)

      callback
    end
  end

  Workspace.register_provider(:directory, Workspace)
end
