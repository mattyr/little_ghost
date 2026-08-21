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
        unless BACKENDS.include?(backend)
          raise ArgumentError, "backend must be :auto, :thread, or :fiber"
        end

        @backend = backend
      end

      # Starts a Task and returns it immediately.
      def spawn(&work)
        raise ArgumentError, "a task block is required" unless work

        resolved_backend = resolve_backend
        task = build_task(&work)
        worker = if resolved_backend == :fiber
          Fiber.schedule { task.call }
        else
          Thread.new { task.call }
        end
        thread_worker = resolved_backend == :thread
        task.start(worker, terminable: thread_worker, joinable: thread_worker)
      end

      # Starts a Task when capacity is immediately available. The ordinary
      # runner has no shared capacity limit, so it always accepts the task.
      def try_spawn(&work)
        spawn(&work)
      end

      # Indicates that work started from the current execution context will be
      # owned by its active Fiber scheduler.
      def uses_current_scheduler?
        resolve_backend == :fiber
      end

      protected

      def build_task(capture_interruptions: false, &work)
        Task.new(execution_state: ExecutionState.capture, capture_interruptions:, &work)
      end

      def current_scheduler
        Fiber.current_scheduler
      end

      private

      def resolve_backend
        return :thread if backend == :thread

        scheduler = current_scheduler
        return :fiber if scheduler
        if backend == :fiber
          raise ConfigurationError,
            "fiber concurrency requires an active scheduler-managed nonblocking fiber"
        end

        :thread
      end
    end
  end
end
