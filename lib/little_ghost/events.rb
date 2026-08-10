# frozen_string_literal: true

require "json"

module LittleGhost
  # Events lets an application react to noteworthy agent activity without
  # coupling LittleGhost to a logger or event backend. Listeners can feed local
  # diagnostics, alerts, or an application's own event pipeline.
  #
  #   class WarningCollector
  #     attr_reader :events
  #
  #     def initialize
  #       @events = []
  #     end
  #
  #     def emit(event)
  #       events << event
  #     end
  #   end
  #
  #   warnings = WarningCollector.new
  #   LittleGhost::Events.subscribe(warnings) do |event|
  #     %i[warn error].include?(event[:level])
  #   end
  #   LittleGhost::Events.warn("support.case.stalled", case_id: "case-42")
  #   warnings.events.last[:name] # => "support.case.stalled"
  #
  # Events describe point-in-time facts. Instrumentation measures work that has
  # a start and finish. Payloads are copied, limited to JSON-safe values, and
  # delivered with context local to the current execution. A broken listener
  # never breaks the operation that emitted the event.
  module Events
    # Severity levels accepted by .emit and its convenience methods.
    LEVELS = %i[debug info warn error].freeze

    # JSON-lines listener suitable for diagnostics and local development.
    # Values pass through a Support::Redactor before being written.
    class ConsoleListener
      # Writes redacted JSON lines to +io+.
      def initialize(io: $stderr, redactor: Support::Redactor.new)
        @io = io
        @redactor = redactor
        @mutex = Mutex.new
      end

      # Emits one complete JSON line atomically.
      def emit(event)
        @mutex.synchronize { @io.puts(JSON.generate(@redactor.call(event))) }
      end
    end

    # Thread-safe event publisher with process-wide and fiber-scoped listeners.
    class Reporter
      # Starts with +listeners+ in subscription order.
      def initialize(listeners: [ConsoleListener.new])
        @mutex = Mutex.new
        @listeners = []
        Array(listeners).each { |listener| subscribe(listener) }
      end

      # Subscribes +listener+. The optional block filters copied event hashes.
      def subscribe(listener, &filter)
        unless listener.respond_to?(:emit)
          raise ArgumentError, "event listener must respond to emit"
        end

        @mutex.synchronize { @listeners << {listener:, filter:} }
        listener
      end

      # Unsubscribes every entry matching +listener+.
      def unsubscribe(listener)
        @mutex.synchronize do
          @listeners.delete_if { |entry| listener === entry.fetch(:listener) }
        end
        listener
      end

      # Delivers an event and returns a detached copy of its complete hash.
      def emit(level, name, payload = {})
        level = level.to_sym
        raise ArgumentError, "unknown event level: #{level}" unless LEVELS.include?(level)
        raise ArgumentError, "event payload must be a hash" unless payload.is_a?(Hash)

        event = {
          name: normalize_string(name.to_s),
          level:,
          payload: deep_copy(payload),
          context: context,
          timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
        }
        listeners.each do |entry|
          listener = entry.fetch(:listener)
          filter = entry[:filter]
          next if filter && !filter.call(deep_copy(event))

          listener.emit(deep_copy(event))
        rescue
          nil
        end
        event
      end

      # Adds attributes to events emitted while the block runs.
      def with_context(attributes)
        values = context.merge(deep_copy(attributes.compact))
        ExecutionState.with(context_key => values) { yield }
      end

      # Copies the event context active in the current execution.
      def context
        deep_copy(ExecutionState[context_key] || {})
      end

      private

      def listeners
        scoped = ExecutionState[:little_ghost_event_listeners] || []
        @mutex.synchronize { @listeners.dup } + scoped
      end

      def context_key = :little_ghost_event_context

      def deep_copy(value, ancestors = {}, depth = 0)
        raise ArgumentError, "event payload is nested too deeply" if depth > 100

        case value
        when Hash
          copy_container(value, ancestors) do
            value.to_h do |key, item|
              unless key.is_a?(String) || key.is_a?(Symbol)
                raise ArgumentError, "event payload keys must be strings or symbols"
              end

              [copy_key(key), deep_copy(item, ancestors, depth + 1)]
            end
          end
        when Array
          copy_container(value, ancestors) do
            value.map { |item| deep_copy(item, ancestors, depth + 1) }
          end
        when String
          normalize_string(value)
        when Float
          raise ArgumentError, "event payload numbers must be finite" unless value.finite?

          value
        when Symbol
          copy_symbol(value)
        when Integer, true, false, nil
          value
        else
          raise ArgumentError, "event payload values must be JSON-safe"
        end
      end

      def copy_container(value, ancestors)
        identity = value.object_id
        raise ArgumentError, "event payload must not contain cycles" if ancestors.key?(identity)

        ancestors[identity] = true
        yield
      ensure
        ancestors.delete(identity) if identity
      end

      def copy_key(key)
        return copy_symbol(key) if key.is_a?(Symbol)

        normalize_string(key.to_s)
      end

      def copy_symbol(value)
        text = value.to_s
        return value if text.ascii_only? || (text.encoding == Encoding::UTF_8 && text.valid_encoding?)

        normalize_string(text)
      end

      def normalize_string(value)
        value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      end
    end

    class << self
      # Accesses the process-wide reporter.
      def reporter
        reporter_mutex.synchronize { @reporter ||= Reporter.new }
      end

      # Replaces the process-wide reporter. Existing references are unaffected.
      def reporter=(value)
        raise ArgumentError, "reporter must be an event reporter" unless value.is_a?(Reporter)

        reporter_mutex.synchronize { @reporter = value }
      end

      # Subscribes a process-wide listener.
      def subscribe(...) = reporter.subscribe(...)
      # Unsubscribes a process-wide listener.
      def unsubscribe(...) = reporter.unsubscribe(...)
      # Adds event context while a block runs.
      def with_context(...) = reporter.with_context(...)
      # Copies the current event context.
      def context = reporter.context

      LEVELS.each do |level|
        define_method(level) do |name, payload = nil, **attributes|
          if payload && !payload.is_a?(Hash)
            raise ArgumentError, "event payload must be a hash"
          end

          values = payload ? payload.merge(attributes) : attributes
          reporter.emit(level, name, values)
        end
      end

      # Subscribes +listener+ only while the block runs.
      def subscribed(listener, &block)
        raise ArgumentError, "event listener must respond to emit" unless listener.respond_to?(:emit)

        listeners = ExecutionState[:little_ghost_event_listeners] || []
        entry = {listener:, filter: nil}
        ExecutionState.with(little_ghost_event_listeners: listeners + [entry], &block)
      end

      private

      def reporter_mutex
        @reporter_mutex ||= Mutex.new
      end
    end
  end
end
