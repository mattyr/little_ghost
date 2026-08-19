# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Lifecycle contract for one Engine's active program.
    #
    # LittleGhost's Agent runtime serializes +execute+, +wait+, and +stop+ for a
    # Session. Direct callers must also avoid overlap; built-in Sessions reject
    # concurrent control operations. An implementation applies the supplied
    # limits, observes RunContext cancellation, keeps model-written execution
    # inside its Sandbox, and routes Tool calls through the parent-process
    # Broker.
    #
    # Each control operation returns a ProgramResult. Built-in engines use
    # +:completed+ when execution ended successfully,
    # +:still_working+ when an observation interval elapsed, +:terminated+ after
    # requested termination, and +:error+ for a model-program error. +wait+
    # observes an active program without pausing, resuming, or restarting it.
    # Lifecycle, host, and cleanup failures raise rather than becoming a result.
    #
    #   ProgramResult.new(
    #     output: "",
    #     value: nil,
    #     status: :completed,
    #     error: nil
    #   )
    class Session
      # Starts a fresh program from +source+ and returns its first ProgramResult.
      # +catalog+ is the Tool catalog used to compile the source contract.
      # +max_output_tokens+ bounds output returned for this observation.
      # +frame+ is optional engine-specific data from a trusted caller. The Ruby
      # engine exposes JSON-compatible frame data to model-authored code as
      # +FRAME+, so it must not contain secrets. The JavaScript engine ignores
      # it. Portable callers should leave it +nil+.
      def execute(source:, catalog:, frame: nil, max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session must execute source"
      end

      # Observes the active program and returns its next ProgramResult.
      # Its +output+ contains text produced since the previous observation.
      # Raises when no program is active or cleanup cannot finish.
      def wait(max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session does not support waiting"
      end

      # Terminates the active program and returns a +:terminated+ ProgramResult
      # with its final incremental output. Raises when no program is active or
      # cleanup cannot finish.
      def stop(max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session does not support stopping"
      end

      # Closes all owned resources. A successful close is idempotent. Direct
      # callers must not overlap it with a control operation. The method raises
      # when the implementation cannot establish a clean ending. Built-in
      # Sessions use CleanupError for bounded cleanup failures and may propagate
      # an error raised while closing an owned resource.
      def close = nil
    end
  end
end
