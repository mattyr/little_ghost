# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Lifecycle contract for one Engine's active program.
    #
    # LittleGhost serializes +execute+, +wait+, and +stop+ for a Session. Implementations
    # must reject unsafe overlap if they are called outside that runtime. They
    # must apply the supplied limits, observe RunContext cancellation, keep
    # model-authored execution inside their Sandbox, and route Tool calls through
    # the parent-process Broker.
    #
    # Every operation returns a CellResult with +output+, +value+, +status+, and
    # +error+ fields. Built-in engines use +:completed+ when execution ended,
    # +:still_working+ when an observation interval elapsed, +:terminated+ after
    # requested termination, and +:error+ for a model-program error. +wait+
    # observes an active program without pausing, resuming, or restarting it.
    # Lifecycle, host, and cleanup failures raise rather than becoming a result.
    #
    #   CellResult.new(
    #     output: "",
    #     value: nil,
    #     status: :completed,
    #     error: nil
    #   )
    class Session
      # Starts a fresh program from +source+ and returns its first observation.
      # +catalog+ is the Tool catalog used to compile the source contract.
      # +max_output_tokens+ bounds output returned for this observation.
      # +frame+ is optional engine-specific data from a trusted caller. The Ruby
      # engine exposes JSON-compatible frame data to model-authored code as
      # +FRAME+, so it must not contain secrets. The JavaScript engine ignores
      # it. Portable callers should leave it +nil+.
      def execute(source:, catalog:, frame: nil, max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session must execute source"
      end

      # Observes the active program and returns output produced since the previous
      # observation. Raises when no program is active or cleanup cannot finish.
      def wait(max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session does not support waiting"
      end

      # Terminates the active program and returns its final incremental output.
      # Raises when no program is active or cleanup cannot finish.
      def stop(max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session does not support stopping"
      end

      # Closes all owned resources. It must be safe to call more than once and
      # must raise CleanupError when the implementation cannot establish a clean
      # ending.
      def close = nil
    end
  end
end
