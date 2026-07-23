# frozen_string_literal: true

require "erb"

module LittleGhost
  module Templates
    TrustedPath = Data.define(:path) do
      def initialize(path:)
        expanded = File.realpath(path)
        raise ArgumentError, "trusted template path must be a directory" unless File.directory?(expanded)
        super(path: expanded.freeze)
      rescue Errno::ENOENT
        raise ArgumentError, "trusted template path must exist"
      end
    end

    Root = Data.define(:path, :boundary) do
      def initialize(path:, boundary: nil)
        super(path: File.expand_path(path).freeze, boundary: boundary && File.expand_path(boundary).freeze)
      end
    end

    class Error < LittleGhost::Error; end
    class MissingTemplateError < Error; end
    class InvalidTemplateError < Error; end
    class MissingLocalError < Error; end

    class Resolver
      DEFAULT_MAX_DEPTH = 20

      def initialize(application_paths: [], gem_paths: [], max_depth: DEFAULT_MAX_DEPTH)
        @application_paths = normalize_roots(application_paths)
        @gem_paths = normalize_roots(gem_paths)
        @max_depth = Integer(max_depth)
        raise ArgumentError, "max_depth must be positive" unless @max_depth.positive?

        @cache = {}
        @cache_mutex = Mutex.new
      end

      def render(name, locals: {}, invocation_paths: [])
        roots = normalize_invocation_roots(invocation_paths) + @application_paths + @gem_paths
        render_template(normalize_name(name), locals, roots, [])
      end

      private

      def render_template(name, locals, roots, stack)
        raise InvalidTemplateError, "Template recursion exceeds #{@max_depth} levels" if stack.length >= @max_depth

        path = resolve(name, roots)
        raise InvalidTemplateError, "Template cycle detected: #{(stack + [path]).join(" -> ")}" if stack.include?(path)

        template = compiled_template(path)
        context = RenderContext.new(self, roots, stack + [path], name, locals)
        template.result(context.template_binding)
      rescue NameError => error
        if error.name && local_name?(error.name)
          raise MissingLocalError, "Missing template local: #{error.name}"
        end

        raise
      end

      def render_partial(name, locals, roots, stack, parent_name)
        logical_name = partial_name(name, parent_name)
        render_template(logical_name, locals, roots, stack)
      end

      def partial_name(name, parent_name)
        normalized = normalize_name(name)
        directory = File.dirname(parent_name)
        directory = "" if directory == "."
        basename = File.basename(normalized)
        basename = "_#{basename}" unless basename.start_with?("_")
        path = File.join(File.dirname(normalized), basename)
        path = File.join(directory, path) unless directory.empty? || name.to_s.include?("/")
        path
      end

      def resolve(name, roots)
        candidates = template_candidates(name)
        roots.each do |root_spec|
          root, real_root = validate_root(root_spec)
          candidates.each do |candidate|
            path = File.expand_path(candidate, root)
            next unless inside_root?(path, root) && File.file?(path)

            real_path = File.realpath(path)
            return real_path if inside_root?(real_path, real_root)
          end
        end

        raise MissingTemplateError, "Template not found: #{name}"
      end

      def template_candidates(name)
        name.end_with?(".erb") ? [name] : ["#{name}.erb", name]
      end

      def compiled_template(path)
        stat = File.stat(path)
        fingerprint = [stat.mtime.to_r, stat.size]

        @cache_mutex.synchronize do
          cached = @cache[path]
          return cached[:template] if cached && cached[:fingerprint] == fingerprint

          template = ERB.new(File.read(path), trim_mode: "-")
          @cache[path] = {fingerprint: fingerprint, template: template}
          template
        end
      end

      def normalize_roots(paths)
        Array(paths).map do |path|
          path.is_a?(Root) ? path : Root.new(path: path.to_s)
        end.freeze
      end

      def normalize_invocation_roots(paths)
        Array(paths).map do |path|
          unless path.is_a?(TrustedPath)
            raise ArgumentError, "invocation template paths must be LittleGhost::Templates::TrustedPath values"
          end
          Root.new(path: path.path)
        end.freeze
      end

      def validate_root(root)
        real_root = File.realpath(root.path)
        raise InvalidTemplateError, "Template root is not a directory" unless File.directory?(real_root)
        if root.boundary
          boundary = File.realpath(root.boundary)
          unless inside_root?(real_root, boundary)
            raise InvalidTemplateError, "Template root escapes its trusted boundary"
          end
        end
        [root.path, real_root]
      rescue Errno::ENOENT
        [root.path, root.path]
      end

      def normalize_name(name)
        value = String(name)
        path_parts = value.split(/[\\\/]/)
        if value.empty? || value.include?("\0") || File.absolute_path(value) == value || path_parts.include?("..")
          raise InvalidTemplateError, "Unsafe template name: #{value.inspect}"
        end

        value.sub(%r{\A\./}, "")
      end

      def inside_root?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def local_name?(name)
        name.to_s.match?(/\A[a-z_]\w*\z/)
      end

      class RenderContext
        def initialize(resolver, roots, stack, name, locals)
          @resolver = resolver
          @roots = roots
          @stack = stack
          @name = name
          @locals = validate_locals(locals)
        end

        def partial(name, locals: {})
          @resolver.send(:render_partial, name, locals, @roots, @stack, @name)
        end

        def template_binding
          context_binding = binding
          @locals.each { |name, value| context_binding.local_variable_set(name, value) }
          context_binding
        end

        private

        def validate_locals(locals)
          unless locals.respond_to?(:each_pair)
            raise ArgumentError, "locals must be a hash"
          end

          locals.each_with_object({}) do |(name, value), result|
            symbol = name.to_sym
            unless symbol.to_s.match?(/\A[a-z_]\w*\z/)
              raise ArgumentError, "Invalid local name: #{name.inspect}"
            end

            result[symbol] = value
          end
        end
      end
    end
  end
end
