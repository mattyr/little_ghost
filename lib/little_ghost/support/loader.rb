# frozen_string_literal: true

require "pathname"

module LittleGhost
  module Support
    class Loader
      DEFAULT_DIRECTORIES = %w[app/agents app/tools].freeze

      attr_reader :root, :directories

      def initialize(paths: nil, root: nil, directories: DEFAULT_DIRECTORIES)
        @root = root && File.expand_path(root)
        @directories = Array(directories).map(&:to_s).freeze
        if @root && @directories.any? { |directory| Pathname.new(directory).absolute? || directory.split(File::SEPARATOR).include?("..") }
          raise ArgumentError, "application load directories must stay within root"
        end
        roots = paths || @directories.map { |directory| File.join(@root || Dir.pwd, directory) }
        @paths = Array(roots).map { |path| File.expand_path(path) }.uniq.freeze
        @registry = nil
        @loaded_constants = {}
        @setup = false
      end

      def setup
        return self if @setup

        registry.each do |constant_name, path|
          namespace, name = namespace_for(constant_name)
          if namespace.const_defined?(name, false) || namespace.autoload?(name)
            existing = namespace.autoload?(name)
            next if existing && File.expand_path(existing) == path
            raise ConflictError, "#{constant_name} is already defined"
          end
          namespace.autoload(name, path)
        end
        @setup = true
        self
      end

      def eager_load
        setup
        registry.each_key do |constant_name|
          validate_registered_path!(constant_name)
          constantize(constant_name)
          @loaded_constants[constant_name] = registry.fetch(constant_name)
        rescue NameError => error
          raise unless expected_constant_missing?(error, constant_name)
          raise ExpectedConstantError, "#{registry.fetch(constant_name)} must define #{constant_name}"
        end
        self
      end

      def find(relative_path)
        clean = clean_path(relative_path)
        @paths.each do |path_root|
          candidate = File.expand_path(clean, path_root)
          next unless inside?(candidate, path_root)
          next unless File.file?(candidate)
          real_candidate = File.realpath(candidate)
          return real_candidate if inside?(real_candidate, real_path_root(path_root))
        end
        nil
      end

      def fetch(relative_path)
        find(relative_path) || raise(LoadError, "Could not find #{relative_path} in configured paths")
      end

      def read(relative_path, encoding: "UTF-8")
        File.read(fetch(relative_path), encoding:)
      end

      def glob(pattern)
        clean = clean_path(pattern)
        @paths.flat_map do |path_root|
          next [] unless Dir.exist?(path_root)
          real_root = real_path_root(path_root)
          Dir.glob(File.join(path_root, clean)).filter_map do |candidate|
            expanded = File.expand_path(candidate)
            next unless inside?(expanded, path_root)
            real_candidate = File.realpath(candidate)
            real_candidate if inside?(real_candidate, real_root)
          rescue Errno::ENOENT
            nil
          end
        end.uniq.sort
      end

      def constant(name)
        setup
        constantize(name.to_s)
      rescue NameError => error
        raise unless expected_constant_missing?(error, name.to_s)
        raise ExpectedConstantError, "Unknown application constant: #{name}"
      end

      def registered_constants
        registry.dup.freeze
      end

      def loaded_constant?(name)
        path = @loaded_constants[name.to_s]
        return false unless path && path == registry[name.to_s]

        location = constant_source_location(name.to_s)
        location && File.realpath(location.first) == path
      rescue Errno::ENOENT
        false
      end

      private

      def registry
        @registry ||= @paths.each_with_object({}) do |path_root, index|
          next unless Dir.exist?(path_root)

          Dir.glob(File.join(path_root, "**/*.rb")).sort.each do |path|
            relative = path.delete_prefix("#{path_root}#{File::SEPARATOR}").delete_suffix(".rb")
            constant_name = relative.split(File::SEPARATOR).map { |part| camelize(part) }.join("::")
            expanded = File.realpath(path)
            unless inside?(expanded, real_path_root(path_root))
              raise ConflictError, "Autoload path escapes configured root: #{path}"
            end
            if index.key?(constant_name) && index[constant_name] != expanded
              raise ConflictError, "Multiple files map to #{constant_name}: #{index[constant_name]} and #{expanded}"
            end
            index[constant_name] = expanded
          end
        end.freeze
      end

      def namespace_for(constant_name)
        names = constant_name.split("::")
        name = names.pop
        namespace = names.inject(Object) do |parent, child|
          if parent.const_defined?(child, false)
            value = parent.const_get(child, false)
            raise ConflictError, "#{parent}::#{child} is not a namespace" unless value.is_a?(Module)
            value
          else
            parent.const_set(child, Module.new)
          end
        end
        [namespace, name]
      end

      def constantize(name)
        verbose = $VERBOSE
        $VERBOSE = nil
        name.split("::").inject(Object) { |parent, child| parent.const_get(child, false) }
      ensure
        $VERBOSE = verbose
      end

      def constant_source_location(name)
        names = name.split("::")
        leaf = names.pop
        namespace = Object
        until names.empty?
          child = names.shift
          return if namespace.autoload?(child) || !namespace.const_defined?(child, false)

          namespace = namespace.const_get(child, false)
        end
        return if namespace.autoload?(leaf) || !namespace.const_defined?(leaf, false)

        namespace.const_source_location(leaf, false)
      end

      def camelize(value)
        value.split("_").map do |part|
          raise ConflictError, "Invalid autoload path component: #{value}" unless part.match?(/\A[a-z][a-z0-9]*\z/)
          part[0].upcase + part[1..]
        end.join
      end

      def clean_path(value)
        path = value.to_s
        raise ArgumentError, "path must be relative" if path.empty? || Pathname.new(path).absolute?
        raise ArgumentError, "path cannot escape configured roots" if path.split(File::SEPARATOR).include?("..")
        path
      end

      def inside?(candidate, path_root)
        candidate == path_root || candidate.start_with?("#{path_root}#{File::SEPARATOR}")
      end

      def real_path_root(path_root)
        resolved = File.realpath(path_root)
        if @root && !inside?(resolved, File.realpath(@root))
          raise ConflictError, "Load directory escapes application root: #{path_root}"
        end
        resolved
      end

      def expected_constant_missing?(error, constant_name)
        names = constant_name.split("::")
        return false unless error.name.to_s == names.last

        expected_receiver = names[0...-1].inject(Object) { |parent, child| parent.const_get(child, false) }
        error.receiver.equal?(expected_receiver)
      rescue ArgumentError, NameError
        false
      end

      def validate_registered_path!(constant_name)
        path = registry.fetch(constant_name)
        current = File.realpath(path)
        raise ConflictError, "Autoload path changed after registration: #{path}" unless current == path
      rescue Errno::ENOENT
        raise ConflictError, "Autoload path disappeared after registration: #{path}"
      end

      class ConflictError < Error; end
      class ExpectedConstantError < Error; end
    end
  end
end
