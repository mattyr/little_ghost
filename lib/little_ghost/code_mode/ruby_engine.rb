# frozen_string_literal: true

require_relative "../../little_ghost" unless defined?(LittleGhost::CodeMode::Engine)
require_relative "ruby/catalog"
require_relative "ruby/session"

module LittleGhost
  module CodeMode
    # Runs model-written Ruby in a fresh sandboxed process.
    #
    # Tool calls cross a bounded protocol to the trusted parent Broker. The
    # engine uses only Ruby's standard library and adds no runtime dependency.
    #
    #   LittleGhost.configure do |config|
    #     config.code_mode = {engine: :ruby, sandbox: :native}
    #   end
    class RubyEngine < Engine
      # Resource, Tool-call, and program limits applied when the application
      # does not override them.
      DEFAULT_LIMITS = {
        source_bytes: 1_000_000,
        output_bytes: 1_000_000,
        memory_bytes: 64 * 1024 * 1024,
        wall_seconds: 3_600,
        cpu_seconds: 10,
        file_bytes: 1_000_000,
        programs: 8,
        tool_calls: 1_000,
        concurrency: 8,
        cleanup_seconds: 5
      }.freeze

      # Returns the +:ruby+ language identifier.
      def language = :ruby

      # Builds Ruby usage instructions and method declarations for +catalog+.
      def instructions(catalog:)
        <<~INSTRUCTIONS.strip
          Use Ruby to call the available tools and compose their results.

          Program lifecycle:
          - Every exec call starts a fresh program in a new Ruby process.
          - Exec and wait observe it for up to one minute. They return sooner when it finishes.
          - If exec or wait returns `still_working`, call wait to observe the same running program again.
          - Wait does not pause, resume, or restart the program.
          - Use stop when the result is no longer needed.
          - Do not call wait or stop after `completed`, `error`, or `terminated`.
          - Local variables, constants, and other process state do not persist between exec calls.

          Tool calls:
          - Call a tool with `tools.<method>(keyword: value)` and only its documented keywords.
          - Use `tools.call(name, arguments)` when the name is dynamic.
          - Tool calls are synchronous. Use `tools.parallel` for independent calls; results keep callable order.
          - JSON results become ordinary Ruby values. Other results remain strings.
          - A failed call raises. Rescue it only when the program can recover.
          - `ALL_TOOLS` contains the complete runtime catalog.

          Output and completion:
          - The final Ruby expression becomes the completed program value.
          - Use `text(value)` for user-visible output.
          - Use `finish(value)` to complete early with a value.

          The Sandbox controls filesystem, network, subprocess, and optional-library access. Do not assume host
          capabilities are available.

          Available tool methods:

          #{Ruby::Catalog.new(catalog).declarations}
        INSTRUCTIONS
      end

      # Opens a Ruby Session with engine defaults merged with +limits+.
      # Unsupported limit keys raise ArgumentError.
      def open_session(broker:, sandbox_factory:, limits: {})
        Ruby::Session.new(
          broker:,
          sandbox_factory:,
          subprocess_policy: method(:allow_subprocesses_for),
          limits: normalize_limits(limits, defaults: DEFAULT_LIMITS)
        )
      end
    end

    CodeMode.register_engine(:ruby, RubyEngine)
  end
end
