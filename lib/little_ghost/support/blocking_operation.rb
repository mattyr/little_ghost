# frozen_string_literal: true

module LittleGhost
  module Support
    # Moves framework-owned blocking work off an active scheduler thread. Once
    # started, the caller joins the worker through completion; call sites must
    # provide cooperative cancellation inside interruptible operations rather
    # than abandoning or forcibly killing the worker.
    module BlockingOperation # :nodoc:
      module_function

      def call(&operation)
        return operation.call unless Fiber.current_scheduler

        execution_state = ExecutionState.capture
        worker = Thread.new do
          ExecutionState.with(execution_state, &operation)
        end
        worker.report_on_exception = false
        worker.value
      ensure
        worker&.join
      end
    end
  end
end
