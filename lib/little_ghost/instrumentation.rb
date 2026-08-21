# frozen_string_literal: true

require "securerandom"

module LittleGhost
  # Instrumentation turns agent work into structured lifecycle notifications.
  # Applications can measure agents, models, tools, workflows, and sessions with
  # the telemetry backend they already use.
  #
  #   class TimingSubscriber < LittleGhost::Instrumentation::Subscriber
  #     def finish(name, attributes)
  #       puts "#{name}: #{attributes.fetch(:duration_ms)}ms"
  #     end
  #   end
  #
  #   LittleGhost.configure do |config|
  #     config.instrument TimingSubscriber.new
  #   end
  #
  # A subscriber receives structured attributes when an operation starts,
  # finishes, or emits a point-in-time event. Subscriber failures are reported
  # once and kept separate from agent execution.
  #
  # === Content and trust
  #
  # Diagnostic content is excluded unless the application installs an explicit
  # Support::ContentCapture policy. One process is one telemetry and content
  # policy boundary; applications that need different exporters or data policies
  # should use separate processes.
  module Instrumentation
    # Subclass Subscriber to connect a telemetry backend.
    #
    # Override the callbacks a backend supports. +start+ and +finish+ receive the
    # same operation name and correlated attributes. +emit+ receives point
    # events. Implementations may return a propagation carrier from
    # #trace_context. Callbacks should be safe across threads and interleaved
    # fibers.
    class Subscriber
      # Called when a lifecycle operation starts.
      def start(_name, _attributes) = nil
      # Called when a lifecycle operation finishes.
      def finish(_name, _attributes) = nil
      # Called for a point-in-time instrumentation event.
      def emit(_name, _attributes) = nil
      # Flushes buffered telemetry within an optional timeout budget.
      def flush(timeout: nil) = nil
      # Releases subscriber resources within an optional timeout budget.
      def shutdown(timeout: nil) = nil
      # Supplies trace fields that should travel with downstream work.
      def trace_context(**) = {}
    end

    # A Handle represents work between Instrumentation.start and #finish.
    #
    # Non-detached handles are fiber-owned and must finish in LIFO order after
    # their children. Detached handles may finish outside the creating fiber but
    # still cannot finish while local children remain active.
    class Handle
      # Operation identity, inherited attributes, previous local handle, and
      # monotonic start time.
      attr_reader :name, :operation_id, :parent_operation_id, :payload, :previous, :started_at

      def initialize(bus, name, operation_id:, parent_operation_id:, local_parent:, previous:, payload:, started_at:, detached:) # :nodoc:
        @bus = bus
        @name = name.to_sym
        @operation_id = operation_id
        @parent_operation_id = parent_operation_id
        @local_parent = local_parent
        @previous = previous
        @payload = payload
        @started_at = started_at
        @detached = detached
        @owner = Fiber.current
      end

      # Completes this operation with additional attributes.
      def finish(**attributes)
        @bus.finish(self, **attributes)
      end

      # Indicates whether this handle belongs to the current fiber.
      def owner? = @owner.equal?(Fiber.current)
      # Indicates whether this handle is outside the fiber-local operation stack.
      def detached? = @detached
      # Indicates whether the parent is another active handle on this bus.
      def local_parent? = @local_parent
      # Indicates whether this handle is still active.
      def active? = @bus.active?(self)
    end

    # Thread-safe notification bus used by the process-wide Instrumentation API.
    class Bus
      # Starts an independent bus with ordered subscribers and a content policy.
      def initialize(subscribers: [], content_capture: Support::ContentCapture.disabled)
        @subscribers = []
        @content_capture = content_capture
        @handles = {}
        @children = Hash.new(0)
        @finishing = {}
        @mutex = Mutex.new
        @reported_failures = {}
        @shutdown = false
        Array(subscribers).each { |subscriber| subscribe(subscriber) }
      end

      # Subscribes a backend once. +prepend+ controls notification order.
      def subscribe(subscriber, prepend: false)
        unless subscriber.is_a?(Subscriber)
          raise ArgumentError, "instrumentation subscriber must be a LittleGhost::Instrumentation::Subscriber"
        end

        @mutex.synchronize do
          @subscribers.reject! { |listener| listener.equal?(subscriber) }
          prepend ? @subscribers.unshift(subscriber) : @subscribers << subscriber
        end
        subscriber
      end

      # Unsubscribes a backend by identity.
      def unsubscribe(subscriber)
        @mutex.synchronize { @subscribers.reject! { |listener| listener.equal?(subscriber) } }
        subscriber
      end

      # Selects the diagnostic content policy used for future notifications.
      def capture_content(policy)
        raise ArgumentError, "content capture policy must respond to capture" unless policy.respond_to?(:capture)

        @mutex.synchronize { @content_capture = policy }
        policy
      end

      # Publishes a point event with the current context and operation ID.
      def publish(name, diagnostic: nil, **attributes)
        current_handle = current
        values = context.merge(attributes)
        values[:operation_id] ||= current_handle&.operation_id
        values = prepare_attributes(values.compact, diagnostic:)
        notify(:emit, name.to_sym, values)
        values
      end

      # Starts an operation. +parent+ may be a local Handle, a remote operation
      # ID, or nil. Set +detached+ for work that will not finish in stack order.
      def start(name, parent: current, operation_id: SecureRandom.uuid, detached: false, diagnostic: nil, **attributes)
        previous = current unless detached
        validate_parent!(parent)
        parent_operation_id = parent.is_a?(Handle) ? parent.operation_id : parent
        payload = context.merge(attributes).merge(operation_id:, parent_operation_id:).compact
        payload = prepare_attributes(payload, diagnostic:)
        handle = Handle.new(
          self,
          name,
          operation_id:,
          parent_operation_id:,
          local_parent: parent.is_a?(Handle),
          previous:,
          payload:,
          started_at: monotonic_time,
          detached:
        )
        @mutex.synchronize do
          raise Error, "instrumentation is shut down" if @shutdown
          raise ArgumentError, "instrumentation operation is already active" if @handles.key?(operation_id)
          if parent.is_a?(Handle)
            raise Error, "instrumentation parent is not active" unless @handles[parent.operation_id].equal?(parent)
            raise Error, "instrumentation parent is finishing" if @finishing.key?(parent.operation_id)
          end

          @handles[operation_id] = handle
          @children[parent_operation_id] += 1 if parent.is_a?(Handle)
        end
        set_current(handle) unless detached
        notify(:start, handle.name, handle.payload)
        handle
      rescue
        abandon(handle) if handle
        raise
      end

      # Finishes an active handle and returns the final attribute hash.
      def finish(handle, diagnostic: nil, **attributes)
        validate_finish!(handle)
        validated = true
        values = handle.payload.merge(attributes).merge(duration_ms: elapsed_ms(handle.started_at))
        values = prepare_attributes(values.compact, diagnostic:)
        notify(:finish, handle.name, values)
        values
      ensure
        complete(handle) if validated && active_handle?(handle)
      end

      # Measures a block and records raised errors before re-raising them.
      def instrument(name, payload = {})
        values = payload.dup
        handle = start(name, **values)
        result = yield values if block_given?
        handle.finish(**values)
        result
      rescue => error
        values ||= payload.dup
        values[:outcome] ||= :error
        values[:error_type] ||= error.class.name
        values[:diagnostic] ||= {exception: diagnostic_exception(error)}
        handle.finish(**values) if handle && active_handle?(handle)
        raise
      end

      # Adds copied attributes to notifications emitted while the block runs.
      def with_context(attributes)
        values = deep_copy(context).merge(deep_copy(attributes.compact))
        ExecutionState.with(context_key => values) { yield }
      end

      # Copies the attributes active in the current execution.
      def context
        deep_copy(ExecutionState[context_key] || {})
      end

      # Finds the current non-detached Handle for this fiber, if any.
      def current
        ExecutionState[current_key]
      end

      # With a handle, tests whether that exact handle is active. Without one,
      # reports whether the bus owns any active operations.
      def active?(handle = nil)
        @mutex.synchronize do
          handle ? @handles[handle.operation_id].equal?(handle) : !@handles.empty?
        end
      end

      # Flushes subscribers in registration order within an optional total
      # timeout budget.
      def flush(timeout: nil)
        deadline = monotonic_time + Float(timeout) if timeout
        subscribers.each do |subscriber|
          remaining = deadline && [deadline - monotonic_time, 0].max
          notify_subscriber(subscriber, :flush, timeout: remaining)
        end
      end

      # Permanently shuts down this bus after all operations have finished.
      def shutdown(timeout: nil)
        should_shutdown = @mutex.synchronize do
          return if @shutdown
          raise Error, "cannot shut down instrumentation with active operations" unless @handles.empty?

          @shutdown = true
        end
        return unless should_shutdown

        deadline = monotonic_time + Float(timeout) if timeout
        subscribers.reverse_each do |subscriber|
          remaining = deadline && [deadline - monotonic_time, 0].max
          notify_subscriber(subscriber, :shutdown, timeout: remaining)
        end
      end

      # Uses the first non-empty downstream trace context supplied by a subscriber.
      def trace_context(**attributes)
        subscribers.each do |subscriber|
          value = subscriber.trace_context(**attributes)
          return value unless value.nil? || value.empty?
        rescue => error
          warn_failure(error, component: :subscriber)
        end
        {}
      end

      private

      def validate_parent!(parent)
        return unless parent
        unless parent.is_a?(Handle) || parent.is_a?(String)
          raise ArgumentError, "instrumentation parent must be a handle or remote operation ID"
        end
      end

      def validate_finish!(handle)
        raise ArgumentError, "instrumentation handle is required" unless handle.is_a?(Handle)
        unless handle.detached?
          raise Error, "instrumentation handle belongs to another fiber" unless handle.owner?
          raise Error, "instrumentation operations must finish in nesting order" unless current.equal?(handle)
        end

        @mutex.synchronize do
          raise Error, "instrumentation operation is not active" unless @handles[handle.operation_id].equal?(handle)
          raise Error, "instrumentation operation is already finishing" if @finishing.key?(handle.operation_id)
          raise Error, "instrumentation operation has active children" unless @children[handle.operation_id].zero?

          @finishing[handle.operation_id] = true
        end
      end

      def active_handle?(handle)
        active?(handle)
      end

      def complete(handle)
        @mutex.synchronize do
          @handles.delete(handle.operation_id)
          @children.delete(handle.operation_id)
          @finishing.delete(handle.operation_id)
          if handle.local_parent?
            @children[handle.parent_operation_id] -= 1
          end
        end
        set_current(handle.previous) if current.equal?(handle)
      end

      def abandon(handle)
        complete(handle) if active_handle?(handle)
      end

      def set_current(handle)
        if handle
          ExecutionState[current_key] = handle
        else
          ExecutionState.delete(current_key)
        end
      end

      def prepare_attributes(attributes, diagnostic:)
        return attributes unless diagnostic

        policy = @mutex.synchronize { @content_capture }
        attributes.merge(policy.capture(diagnostic))
      rescue => error
        warn_failure(error, component: :content_capture)
        attributes
      end

      def notify(method, name, attributes)
        event_subscribers.each do |subscriber|
          notify_subscriber(subscriber, method, name, deep_copy(attributes))
        end
      end

      def notify_subscriber(subscriber, method, ...)
        subscriber.public_send(method, ...)
      rescue => error
        warn_failure(error, component: :subscriber)
      end

      def subscribers
        @mutex.synchronize { @subscribers.dup }
      end

      def event_subscribers
        scoped = ExecutionState[:instrumentation_subscribers] || []
        prepended, appended = scoped.partition { |entry| entry.fetch(:prepend) }
        prepended.map { |entry| entry.fetch(:subscriber) } + subscribers +
          appended.map { |entry| entry.fetch(:subscriber) }
      end

      def deep_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [key, deep_copy(item)] }
        when Array
          value.map { |item| deep_copy(item) }
        when String
          value.dup
        else
          value
        end
      end

      def context_key = :little_ghost_instrumentation_context
      def current_key = :little_ghost_instrumentation_current

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started_at)
        ((monotonic_time - started_at) * 1_000).round(3)
      end

      def diagnostic_exception(error)
        {
          type: error.class.name,
          message: error.message,
          stacktrace: Array(error.backtrace).join("\n")
        }
      end

      def warn_failure(error, component:)
        return if ExecutionState[:little_ghost_instrumentation_failure_event]

        failure = [component, error.class.name]
        report = @mutex.synchronize do
          next false if @reported_failures.key?(failure)

          @reported_failures[failure] = true
        end
        return unless report

        ExecutionState.with(little_ghost_instrumentation_failure_event: true) do
          Events.warn(
            "little_ghost.instrumentation.listener_failed",
            component:,
            error_type: error.class.name
          )
        end
      rescue
        nil
      end
    end

    class << self
      # Accesses the process-wide Bus.
      def notifier = bus

      # Replaces the process-wide bus when it has no active operations.
      def notifier=(value)
        raise ArgumentError, "notifier must be an instrumentation bus" unless value.is_a?(Bus)

        notifier_mutex.synchronize do
          if @bus && !@bus.equal?(value) && @bus.active?
            raise Error, "cannot replace instrumentation notifier with active operations"
          end

          @bus = value
        end
      end

      # Subscribes a process-wide backend.
      def subscribe(...) = bus.subscribe(...)
      # Unsubscribes a process-wide backend.
      def unsubscribe(...) = bus.unsubscribe(...)
      # Installs the process-wide diagnostic content policy.
      def capture_content(...) = bus.capture_content(...)
      # Publishes a point event on the process-wide bus.
      def publish(...) = bus.publish(...)
      # Starts a lifecycle operation on the process-wide bus.
      def start(...) = bus.start(...)
      # Wraps a block in a lifecycle operation.
      def instrument(...) = bus.instrument(...)
      # Returns the current fiber's active Handle.
      def current = bus.current
      # Adds attributes while the block runs.
      def with_context(attributes, &block) = bus.with_context(attributes, &block)
      # Copies the current instrumentation context.
      def context = bus.context
      # Flushes process-wide subscribers.
      def flush(...) = bus.flush(...)
      # Shuts down the process-wide bus.
      def shutdown(...) = bus.shutdown(...)
      # Gets downstream trace fields from process-wide subscribers.
      def trace_context(...) = bus.trace_context(...)

      # Temporarily subscribes a backend for the block's execution state.
      def subscribed(subscriber, prepend: false)
        unless subscriber.is_a?(Subscriber)
          raise ArgumentError, "instrumentation subscriber must be a LittleGhost::Instrumentation::Subscriber"
        end

        subscribers = ExecutionState[:instrumentation_subscribers] || []
        entry = {subscriber:, prepend:}
        ExecutionState.with(instrumentation_subscribers: subscribers + [entry]) { yield }
      end

      private

      def bus
        @bus ||= Bus.new
      end

      def notifier_mutex
        @notifier_mutex ||= Mutex.new
      end
    end
  end
end
