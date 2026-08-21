# frozen_string_literal: true

require "erb"

module LittleGhost
  # TrustedPath marks a caller-supplied prompt directory as trusted application
  # code. Invocation-specific prompt roots must use this wrapper.
  #
  # Invocation paths must use this wrapper. Construction resolves symbolic
  # links immediately and rejects missing or non-directory paths.
  TrustedPath = Data.define(:path) do # :nodoc:
    def initialize(path:)
      expanded = File.realpath(path)
      raise ArgumentError, "trusted template path must be a directory" unless File.directory?(expanded)
      super(path: expanded.freeze)
    rescue Errno::ENOENT
      raise ArgumentError, "trusted template path must exist"
    end
  end

  # Marks a caller-supplied prompt directory as trusted application code.
  # Construction resolves symbolic links immediately and rejects paths that are
  # missing or are not directories.
  #
  # === Choosing prompt directories
  #
  # ERB templates run as Ruby inside the current process. TrustedPath checks that
  # a directory exists and resolves symbolic links; it cannot tell who may edit
  # that directory. Create these values only from application-configured,
  # non-user-writable roots, never from a request or model-selected path.
  class TrustedPath < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(path:) -> TrustedPath
    #
    # Resolves +path+ to an existing directory the caller asserts is trusted
    # prompt code. This checks existence and type, not ownership or permissions.

    ##
    # :attr_reader: path
    # The resolved, existing directory asserted as trusted by the caller.
  end

  # Base error raised while locating or rendering a prompt template.
  class PromptTemplateError < Error; end
  # Raised when no configured root contains the requested template.
  class MissingPromptTemplateError < PromptTemplateError; end
  # Raised for unsafe names, escaped roots, cycles, or excessive recursion.
  class InvalidPromptTemplateError < PromptTemplateError; end
  # Raised when an ERB template references a missing local variable.
  class MissingPromptLocalError < PromptTemplateError; end

  # PromptResolver turns conventional ERB files into an agent's system prompt. It
  # supports ordered application roots and partials without allowing a template
  # name to escape those roots.
  #
  #   resolver = LittleGhost::PromptResolver.new(paths: ["app/prompts"])
  #   prompt = resolver.render("support/system", locals: {product: "Acme"})
  #   prompt.include?("Acme") # => true
  #
  # In +support/system.erb+:
  #
  #   <%= partial "shared/rules", locals: {product: product} %>
  #
  # Earlier invocation roots override configured roots. Template names must be
  # relative, and both lexical traversal and symbolic-link escapes are rejected.
  # Partials use an underscore-prefixed filename and receive only their
  # explicitly supplied locals.
  #
  # Every configured root is trusted Ruby code because ERB executes inside the
  # current process. Keep roots application-controlled and non-user-writable.
  # See the {Prompts as Views guide}[rdoc-ref:docs/guides/prompt_views.md] for the
  # conventional Agent workflow.
  class PromptResolver
    DEFAULT_MAX_DEPTH = 20 # :nodoc:

    # Configures ordered application roots and a partial recursion bound, which
    # defaults to 20 nested templates.
    def initialize(paths: [], max_depth: DEFAULT_MAX_DEPTH)
      @paths = normalize_roots(paths)
      @max_depth = Integer(max_depth)
      raise ArgumentError, "max_depth must be positive" unless @max_depth.positive?

      @cache = {}
      @cache_mutex = Mutex.new
    end

    # Renders +name+ with validated local variables.
    #
    # +invocation_paths+ accepts only TrustedPath values because those roots
    # take precedence over application configuration. The wrapper records the
    # directory selected by application code; it does not inspect who can modify
    # that directory.
    def render(name, locals: {}, invocation_paths: [])
      roots = normalize_invocation_roots(invocation_paths) + @paths
      render_template(normalize_name(name), locals, roots, [])
    end

    private

    def render_template(name, locals, roots, stack)
      raise InvalidPromptTemplateError, "Prompt template recursion exceeds #{@max_depth} levels" if stack.length >= @max_depth

      path = resolve(name, roots)
      raise InvalidPromptTemplateError, "Prompt template cycle detected: #{(stack + [path]).join(" -> ")}" if stack.include?(path)

      template = compiled_template(path)
      context = RenderContext.new(self, roots, stack + [path], name, locals)
      template.result(context.template_binding)
    rescue NameError => error
      if error.name && local_name?(error.name)
        raise MissingPromptLocalError, "Missing prompt template local: #{error.name}"
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

      raise MissingPromptTemplateError, "Prompt template not found: #{name}"
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
        path.is_a?(Lookup::Root) ? path : Lookup::Root.new(path: path.to_s)
      end.freeze
    end

    def normalize_invocation_roots(paths)
      Array(paths).map do |path|
        unless path.is_a?(TrustedPath)
          raise ArgumentError, "invocation template paths must be LittleGhost::TrustedPath values"
        end
        Lookup::Root.new(path: path.path)
      end.freeze
    end

    def validate_root(root)
      real_root = File.realpath(root.path)
      raise InvalidPromptTemplateError, "Prompt template root is not a directory" unless File.directory?(real_root)
      if root.boundary
        boundary = File.realpath(root.boundary)
        unless inside_root?(real_root, boundary)
          raise InvalidPromptTemplateError, "Prompt template root escapes its trusted boundary"
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
        raise InvalidPromptTemplateError, "Unsafe prompt template name: #{value.inspect}"
      end

      value.sub(%r{\A\./}, "")
    end

    def inside_root?(path, root)
      path == root || path.start_with?("#{root}#{File::SEPARATOR}")
    end

    def local_name?(name)
      name.to_s.match?(/\A[a-z_]\w*\z/)
    end

    class RenderContext # :nodoc:
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
