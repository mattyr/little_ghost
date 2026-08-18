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
    module Javascript
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
    # Runs code-mode cells in an isolated V8 context supplied by the optional
    # MiniRacer integration. A cell is one program submitted by the model.
    class JavascriptEngine < Engine
      DEFAULT_LIMITS = {
        output_bytes: 64 * 1024 * 1024,
        memory_bytes: 128 * 1024 * 1024,
        cpu_seconds: 30,
        file_bytes: 1024 * 1024,
        max_concurrency: 8
      }.freeze

      # Returns the +:javascript+ language identifier.
      def language = :javascript

      # Builds JavaScript usage instructions and TypeScript declarations for
      # +catalog+.
      def instructions(catalog:)
        javascript_catalog = Javascript::Catalog.new(catalog)
        <<~INSTRUCTIONS.strip
          Run JavaScript in a fresh V8 context to call the available tools and compose their results. Each submitted
          program is a cell. The context has no Node.js APIs, filesystem, network, console, or WebAssembly. Tool
          functions return Promises; use await or Promise.all. JSON tool results become objects or arrays and other
          results remain strings. Unawaited tool calls are completed before the cell exits. Report output with
          text(value), use yield_control() to yield accumulated output while continuing, and use exit() to complete
          early. ALL_TOOLS is the complete catalog available inside this context.

          #{javascript_catalog.declarations}
        INSTRUCTIONS
      end

      # Opens a JavaScript Session with engine defaults merged with +limits+.
      def open_session(broker:, sandbox_factory:, limits: {})
        configured_limits = DEFAULT_LIMITS.merge(limits.transform_keys(&:to_sym))
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
          max_concurrency: configured_limits.fetch(:max_concurrency)
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
