# frozen_string_literal: true

require_relative "../../little_ghost" unless defined?(LittleGhost::CodeMode::Engine)
require_relative "ruby/catalog"
require_relative "ruby/session"

module LittleGhost
  module CodeMode
    # Dependency-free Ruby code-mode engine. A cell is one program submitted by
    # the model. Every cell receives a fresh Ruby process, and Tool calls cross
    # the bounded protocol to the parent Broker.
    class RubyEngine < Engine
      DEFAULT_LIMITS = {
        source_bytes: 1_000_000,
        output_bytes: 1_000_000,
        memory_bytes: 64 * 1024 * 1024,
        wall_seconds: 10,
        cpu_seconds: 10,
        file_bytes: 1_000_000,
        cells: 8,
        tool_calls: 1_000,
        concurrency: 8,
        cleanup_seconds: 5
      }.freeze

      # Returns the +:ruby+ language identifier.
      def language = :ruby

      # Builds Ruby usage instructions and method declarations for +catalog+.
      def instructions(catalog:)
        <<~INSTRUCTIONS.strip
          Run Ruby in a fresh process to call the available tools and compose their results. Each submitted program is
          a cell. Every exec call starts a new cell. Local variables, constants, and other process state do not persist between exec calls.
          A cell resumed with wait continues in the same process.
          Filesystem, network, subprocess, and optional-library access are controlled by the configured sandbox; do not
          assume host capabilities are available.

          Tools are methods on `tools` and accept keyword arguments exactly as declared below. Calls return decoded
          JSON values as ordinary Ruby values (Hash, Array, String, Numeric, booleans, or nil), and tool failures raise.
          Use `tools.call(name, arguments)` when the tool name is dynamic. Use
          `tools.parallel(-> { tools.first(...) }, -> { tools.second(...) })` for independent calls; results preserve
          callable order. `ALL_TOOLS` contains the complete runtime catalog.

          The cell's final expression is the value returned by exec. Use `text(value)` for user-visible text,
          `finish(value)` to complete early with a value, and `yield_control` to return accumulated output while keeping
          the cell alive for a later wait call. Prefer the named methods and exact keyword arguments documented here:

          #{Ruby::Catalog.new(catalog).declarations}
        INSTRUCTIONS
      end

      # Opens a Ruby Session with engine defaults merged with +limits+.
      def open_session(broker:, sandbox_factory:, limits: {})
        Ruby::Session.new(
          broker:,
          sandbox_factory:,
          subprocess_policy: method(:allow_subprocesses_for),
          limits: DEFAULT_LIMITS.merge(limits.to_h.transform_keys(&:to_sym))
        )
      end
    end

    CodeMode.register_engine(:ruby, RubyEngine)
  end
end
