# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Lifecycle contract for one Engine's active execution state.
    #
    # LittleGhost serializes +execute+ and +wait+ for a Session. Implementations
    # must reject unsafe overlap if they are called outside that runtime. They
    # must apply the supplied limits, observe RunContext cancellation, keep
    # model-authored execution inside their Sandbox, and route Tool calls through
    # the parent-process Broker.
    #
    # Every operation returns a CellResult with +output+, +value+, +status+,
    # +error+, and +continuation+ fields. Built-in engines use +:completed+ when
    # execution ended, +:running+ when an observation interval elapsed,
    # +:yielded+ after an explicit yield, +:terminated+ after requested
    # termination, and +:error+ for a model-program error. +wait+ may continue a
    # running or yielded cell. +continuation+ is engine-owned and opaque.
    # Lifecycle, host, and cleanup failures raise rather than becoming a result.
    #
    #   CellResult.new(
    #     output: "",
    #     value: nil,
    #     status: :completed,
    #     error: nil,
    #     continuation: nil
    #   )
    class Session
      # Starts a fresh cell from +source+ and returns its CellResult.
      # +catalog+ is the Tool catalog used to compile the source contract.
      # +yield_time_ms+ bounds this observation slice, not the cell's total
      # lifetime. +max_output_tokens+ bounds output returned for the slice.
      # +frame+ is optional engine-specific data from a trusted caller. The Ruby
      # engine exposes JSON-compatible frame data to model-authored code as
      # +FRAME+, so it must not contain secrets. The JavaScript engine ignores
      # it. Portable callers should leave it +nil+.
      def execute(source:, catalog:, frame: nil, yield_time_ms: nil, max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session must execute source"
      end

      # Continues or terminates the running or yielded cell and returns its next CellResult.
      # Raise when no active cell exists or when cleanup cannot be completed.
      def wait(yield_time_ms: nil, max_output_tokens: nil, terminate: false, context: nil)
        raise AbstractMethodError, "session does not support waiting"
      end

      # Closes all owned resources. It must be safe to call more than once and
      # must raise CleanupError when the implementation cannot establish a clean
      # ending.
      def close = nil
    end
  end
end
