# frozen_string_literal: true

require "securerandom"

module LittleGhost
  module Instrumentation
    class Handle
      attr_reader :name, :operation_id, :payload, :started_at

      def initialize(name, operation_id:, payload:, started_at:)
        @name = name.to_sym
        @operation_id = operation_id
        @payload = payload
        @started_at = started_at
      end
    end

    class Bus
      def initialize(subscribers: [], content_capture: Support::ContentCapture.disabled, enrichers: [])
        @subscribers = Array(subscribers)
        @content_capture = content_capture
        @enrichers = Array(enrichers)
        @handles = {}
        @mutex = Mutex.new
        @finishing = {}
        @reported_failures = {}
        @shutdown = false
      end

      def subscribe(subscriber = nil, prepend: false, &block)
        listener = subscriber || block
        raise ArgumentError, "A subscriber or block is required" unless listener

        @mutex.synchronize do
          @subscribers.reject! { |subscriber| subscriber.equal?(listener) }
          prepend ? @subscribers.unshift(listener) : @subscribers << listener
        end
        listener
      end

      def unsubscribe(subscriber)
        @mutex.synchronize { @subscribers.reject! { |listener| listener.equal?(subscriber) } }
        subscriber
      end

      def capture_content(policy)
        raise ArgumentError, "content capture policy must respond to capture" unless policy.respond_to?(:capture)

        @mutex.synchronize { @content_capture = policy }
        policy
      end

      def enrich(enricher = nil, &block)
        listener = enricher || block
        raise ArgumentError, "An enricher or block is required" unless listener

        @mutex.synchronize { @enrichers << listener }
        listener
      end

      def publish(name, diagnostic: nil, **attributes)
        attributes = context.merge(attributes)
        policy, enrichers = @mutex.synchronize { [@content_capture, @enrichers.dup] }
        if diagnostic
          begin
            attributes = attributes.merge(policy.capture(diagnostic))
          rescue => error
            warn_failure(error, component: :content_capture)
          end
        end
        enrichers.each do |enricher|
          additions = enricher.call(name.to_sym, deep_copy(attributes))
          attributes = attributes.merge(additions) if additions.is_a?(Hash)
        rescue => error
          warn_failure(error, component: :enricher)
        end
        event_subscribers.each do |subscriber|
          subscriber.call(name.to_sym, deep_copy(attributes))
        rescue => error
          warn_failure(error, component: :subscriber)
        end
        attributes
      end

      def record(name, **attributes)
        event_name = name.to_s
        if event_name.end_with?("_start")
          start(event_name.delete_suffix("_start"), **attributes)
        elsif event_name.end_with?("_stop")
          finish(
            operation_id: attributes.fetch(:operation_id),
            **attributes.except(:operation_id)
          )
        else
          publish(name, **attributes)
        end
      end

      def start(name, operation_id: SecureRandom.uuid, **payload)
        handle = prepare_start(name, operation_id:, **payload)
        published = false
        publish_start(handle)
        published = true
        handle
      ensure
        abandon(handle.operation_id) if handle && !published
      end

      def prepare_start(name, operation_id: SecureRandom.uuid, **payload)
        handle = Handle.new(
          name,
          operation_id:,
          payload: context.merge(payload).merge(operation_id:),
          started_at: monotonic_time
        )
        @mutex.synchronize do
          raise Error, "instrumentation is shut down" if @shutdown
          raise ArgumentError, "instrumentation operation is already active" if @handles.key?(operation_id)

          @handles[operation_id] = handle
        end
        handle
      end

      def publish_start(handle)
        publish(:"#{handle.name}_start", **handle.payload)
      end

      def abandon(operation_id)
        @mutex.synchronize do
          @handles.delete(operation_id)
          @finishing.delete(operation_id)
        end
      end

      def finish(operation_id:, **payload)
        completion = prepare_finish(operation_id:, **payload)
        publish_finish(completion) if completion
      end

      def prepare_finish(operation_id:, **payload)
        handle = @mutex.synchronize do
          next if @finishing[operation_id]

          current = @handles[operation_id]
          @finishing[operation_id] = true if current
          current
        end
        return unless handle

        attributes = handle.payload.merge(payload).merge(
          operation_id:,
          duration_ms: elapsed_ms(handle.started_at)
        )
        [handle, attributes]
      end

      def publish_finish(completion)
        handle, attributes = completion
        publish(:"#{handle.name}_stop", **attributes)
      ensure
        @mutex.synchronize do
          @handles.delete(handle.operation_id)
          @finishing.delete(handle.operation_id)
        end
      end

      def instrument(name, payload = {})
        values = payload.dup
        handle = start(name, **values)
        result = yield values if block_given?
        finish(operation_id: handle.operation_id, **values)
        result
      rescue => error
        values ||= payload.dup
        values[:outcome] ||= :error
        values[:error_type] ||= error.class.name
        values[:diagnostic] ||= {exception: diagnostic_exception(error)}
        finish(operation_id: handle.operation_id, **values) if handle
        raise
      end

      def with_context(attributes)
        values = deep_copy(context).merge(deep_copy(attributes.compact))
        ExecutionState.with(context_key => values) { yield }
      end

      def context
        deep_copy(ExecutionState[context_key] || {})
      end

      def active?
        @mutex.synchronize { !@handles.empty? }
      end

      def flush
        subscribers.each do |subscriber|
          subscriber.flush if subscriber.respond_to?(:flush)
        rescue => error
          warn_failure(error, component: :subscriber)
        end
      end

      def shutdown(timeout: nil)
        should_shutdown = @mutex.synchronize do
          return if @shutdown
          raise Error, "cannot shut down instrumentation with active operations" unless @handles.empty?

          @shutdown = true
        end
        return unless should_shutdown

        deadline = monotonic_time + Float(timeout) if timeout
        subscribers.reverse_each do |subscriber|
          next unless subscriber.respond_to?(:shutdown)

          remaining = deadline && [deadline - monotonic_time, 0].max
          subscriber.shutdown(timeout: remaining)
        rescue => error
          warn_failure(error, component: :subscriber)
        end
      end

      def trace_context(**attributes)
        subscribers.each do |subscriber|
          next unless subscriber.respond_to?(:trace_context)

          value = subscriber.trace_context(**attributes)
          return value unless value.nil? || value.empty?
        rescue => error
          warn_failure(error, component: :subscriber)
        end
        {}
      end

      private

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
      def notifier = bus

      def notifier=(value)
        raise ArgumentError, "notifier must be an instrumentation bus" unless value.is_a?(Bus)

        notifier_mutex.synchronize do
          if @bus && !@bus.equal?(value) && @bus.active?
            raise Error, "cannot replace instrumentation notifier with active operations"
          end

          @bus = value
        end
      end

      def subscribe(...) = bus.subscribe(...)
      def unsubscribe(...) = bus.unsubscribe(...)
      def capture_content(...) = bus.capture_content(...)
      def enrich(...) = bus.enrich(...)
      def publish(...) = bus.publish(...)

      def record(name, **attributes)
        event_name = name.to_s
        if event_name.end_with?("_start")
          start(event_name.delete_suffix("_start"), **attributes)
        elsif event_name.end_with?("_stop")
          finish(
            operation_id: attributes.fetch(:operation_id),
            **attributes.except(:operation_id)
          )
        else
          publish(name, **attributes)
        end
      end

      def start(...)
        target, handle = prepare_start(...)
        publish_start(target, handle)
        handle
      end

      def finish(...)
        target = notifier_mutex.synchronize { bus }
        target.finish(...)
      end

      def instrument(name, payload = {})
        values = payload.dup
        target, handle = prepare_start(name, **values)
        publish_start(target, handle)
        result = yield values if block_given?
        target.finish(operation_id: handle.operation_id, **values)
        result
      rescue => error
        values ||= payload.dup
        values[:outcome] ||= :error
        values[:error_type] ||= error.class.name
        values[:diagnostic] ||= {
          exception: {
            type: error.class.name,
            message: error.message,
            stacktrace: Array(error.backtrace).join("\n")
          }
        }
        target&.finish(operation_id: handle.operation_id, **values) if handle
        raise
      end

      def with_context(attributes, &block) = bus.with_context(attributes, &block)
      def context = bus.context
      def flush = bus.flush
      def shutdown(...) = bus.shutdown(...)
      def trace_context(...) = bus.trace_context(...)

      def subscribed(subscriber, prepend: false)
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

      def prepare_start(...)
        notifier_mutex.synchronize do
          target = bus
          [target, target.prepare_start(...)]
        end
      end

      def publish_start(target, handle)
        published = false
        target.publish_start(handle)
        published = true
      ensure
        target.abandon(handle.operation_id) unless published
      end
    end
  end
end
