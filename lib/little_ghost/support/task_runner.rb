# frozen_string_literal: true

module LittleGhost
  module Support
    # TaskRunner starts framework work on threads or scheduler-owned fibers.
    # +:auto+ uses a fiber only when the calling fiber is managed by an active
    # scheduler. LittleGhost never installs or controls that scheduler.
    class TaskRunner # :nodoc:
      BACKENDS = %i[auto thread fiber].freeze # :nodoc:

      # The configured +:auto+, +:thread+, or +:fiber+ policy.
      attr_reader :backend

      def initialize(backend: :auto)
        backend = backend.to_sym if backend.respond_to?(:to_sym)
        unless BACKENDS.include?(backend)
          raise ArgumentError, "backend must be :auto, :thread, or :fiber"
        end

        @backend = backend
      end

      # Starts a Task and returns it immediately.
      def spawn(&work)
        raise ArgumentError, "a task block is required" unless work

        resolved_backend = resolve_backend
        task = Task.new(
          backend: resolved_backend,
          execution_state: ExecutionState.capture,
          &work
        )
        worker = if resolved_backend == :fiber
          Fiber.schedule { task.call }
        else
          Thread.new { task.call }
        end
        task.start(worker)
      end

      private

      def resolve_backend
        return :thread if backend == :thread

        scheduler = Fiber.current_scheduler
        if scheduler&.respond_to?(:fiber)
          return :fiber
        end
        if backend == :fiber
          raise ConfigurationError,
            "fiber concurrency requires an active scheduler-managed nonblocking fiber"
        end

        :thread
      end
    end
  end
end
