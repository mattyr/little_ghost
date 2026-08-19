# frozen_string_literal: true

require_relative "../../little_ghost"

begin
  require "mini_racer"
rescue LoadError
  raise LittleGhost::DependencyError,
    "JavaScript code mode requires the optional mini_racer gem. Add `gem \"mini_racer\"` to your bundle."
end

require "fileutils"
require "rbconfig"
require "tmpdir"

module LittleGhost
  module CodeMode
    module Javascript # :nodoc:
    end
  end
end

require_relative "protocol"
require_relative "javascript/client"
require_relative "javascript/catalog"
require_relative "javascript/session"
require_relative "javascript/host"

module LittleGhost
  module CodeMode
    # Runs model-written JavaScript in an isolated V8 context.
    #
    # This optional engine uses MiniRacer. Requiring LittleGhost does not load
    # MiniRacer; applications opt in by requiring
    # <tt>little_ghost/code_mode/javascript_engine</tt>.
    class JavascriptEngine < Engine
      # Resource and concurrency limits applied when the application does not
      # override them.
      DEFAULT_LIMITS = {
        output_bytes: 64 * 1024 * 1024,
        memory_bytes: 128 * 1024 * 1024,
        cpu_seconds: 30,
        file_bytes: 1024 * 1024,
        wall_seconds: 3_600,
        max_concurrency: 8
      }.freeze

      # Returns the +:javascript+ language identifier.
      def language = :javascript

      # Builds JavaScript usage instructions and TypeScript declarations for
      # +catalog+.
      def instructions(catalog:)
        javascript_catalog = Javascript::Catalog.new(catalog)
        <<~INSTRUCTIONS.strip
          Use JavaScript to call the available tools and compose their results.

          Program lifecycle:
          - Every exec call starts a fresh program in a new V8 context.
          - Exec and wait observe it for up to one minute. They return sooner when it finishes.
          - If exec or wait returns `still_working`, call wait to observe the same running program again.
          - Wait does not pause, resume, or restart the program.
          - Use stop when the result is no longer needed.
          - Do not call wait or stop after `completed`, `error`, or `terminated`.

          Tool calls:
          - Tool functions return Promises. Use await or Promise.all.
          - JSON results become objects or arrays. Other results remain strings.
          - Unawaited tool calls finish before the program exits.
          - `ALL_TOOLS` contains the complete runtime catalog.

          Output and completion:
          - Use `text(value)` for user-visible output.
          - Use `exit()` to complete early.

          The V8 context has no Node.js APIs, filesystem, network, console, WebAssembly, or process API.

          Available tool methods:

          #{javascript_catalog.declarations}
        INSTRUCTIONS
      end

      # Opens a JavaScript Session with engine defaults merged with +limits+.
      # Unsupported limit keys raise ArgumentError.
      def open_session(broker:, sandbox_factory:, limits: {})
        configured_limits = normalize_limits(limits, defaults: DEFAULT_LIMITS)
        root = Dir.mktmpdir("little-ghost-javascript-")
        runtime_paths = javascript_runtime_paths
        workspace = Workspace.new(
          root:,
          paths: runtime_paths,
          teardown: lambda do |workspace:, **|
            FileUtils.remove_entry_secure(workspace.root) if File.exist?(workspace.root)
          end
        ).open
        sandbox = sandbox_factory.call(
          workspace:,
          required_runtime_paths: runtime_paths.keys.to_h { |name| [name, :read_only] }
        )
        sandbox.open
        client = Javascript::Client.new(session_factory: lambda {
          sandbox.start_program(
            host_command,
            cwd: ".",
            environment: child_environment,
            output_bytes: configured_limits.fetch(:output_bytes),
            memory_bytes: configured_limits[:memory_bytes],
            cpu_seconds: configured_limits[:cpu_seconds],
            file_bytes: configured_limits[:file_bytes],
            allow_subprocesses: allow_subprocesses_for(sandbox)
          )
        })
        Javascript::Session.new(
          broker:, client:, sandbox:, workspace:,
          max_concurrency: configured_limits.fetch(:max_concurrency),
          wall_seconds: configured_limits.fetch(:wall_seconds)
        )
      rescue
        sandbox&.close
        workspace&.close
        FileUtils.remove_entry_secure(root) if root && File.exist?(root)
        raise
      end

      private

      def host_command(specifications: Gem.loaded_specs)
        mini_racer_paths = specifications.fetch("mini_racer").full_require_paths
        [
          RbConfig.ruby,
          *javascript_load_paths(specifications:).flat_map { |path| ["-I", path] },
          "-e", <<~RUBY
            Gem.loaded_specs["mini_racer"] = Struct.new(:require_paths).new(#{mini_racer_paths.inspect})
            require "little_ghost/code_mode/javascript/host"
            LittleGhost::CodeMode::Javascript::Host.run
          RUBY
        ].freeze
      end

      def library_root
        File.expand_path("../..", __dir__)
      end

      def javascript_runtime_paths(specifications: Gem.loaded_specs)
        paths = {runtime: library_root, ruby_runtime: RbConfig::CONFIG.fetch("prefix")}
        %w[mini_racer libv8-node].each do |name|
          specification = specifications.fetch(name)
          key = name.tr("-", "_")
          paths[:"#{key}_gem"] = specification.full_gem_path
          extension_directory = specification.extension_dir
          if File.directory?(extension_directory)
            paths[:"#{key}_extension"] = extension_directory
          end
        end
        paths
      end

      def javascript_load_paths(specifications: Gem.loaded_specs)
        [library_root, *%w[mini_racer libv8-node].flat_map do |name|
          specifications.fetch(name).full_require_paths
        end].uniq
      end

      def child_environment
        {"LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8"}
      end
    end

    register_engine(:javascript, JavascriptEngine)
  end
end
