# frozen_string_literal: true

require "logger"
module LittleGhost
  module Support
    class Instrumentation
      def initialize(subscribers: nil, logger: Logger.new($stderr), content_capture: ContentCapture.disabled, enrichers: [])
        @subscribers = [Tracing::OpenTelemetry.new, *Array(subscribers)]
        @logger = logger
        @content_capture = content_capture
        @enrichers = Array(enrichers)
        @mutex = Mutex.new
      end

      def subscribe(subscriber = nil, prepend: false, &block)
        listener = subscriber || block
        raise ArgumentError, "A subscriber or block is required" unless listener

        @mutex.synchronize { prepend ? @subscribers.unshift(listener) : @subscribers << listener }
        listener
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

      def emit(name, diagnostic: nil, **attributes)
        name = name.to_sym
        policy, enrichers = @mutex.synchronize { [@content_capture, @enrichers.dup] }
        if diagnostic
          begin
            attributes = attributes.merge(policy.capture(diagnostic))
          rescue => error
            warn_failure(error)
          end
        end
        enrichers.each do |enricher|
          additions = enricher.call(name, attributes)
          attributes = attributes.merge(additions) if additions.is_a?(Hash)
        rescue => error
          warn_failure(error)
        end
        attributes = Support.immutable(attributes)
        subscribers.each do |subscriber|
          subscriber.call(name, attributes)
        rescue => error
          @logger.warn("little_ghost instrumentation subscriber failed: #{error.class}")
        end
        attributes
      end

      def flush
        subscribers.each do |subscriber|
          subscriber.flush if subscriber.respond_to?(:flush)
        rescue => error
          warn_failure(error)
        end
      end

      def shutdown
        subscribers.reverse_each do |subscriber|
          subscriber.shutdown if subscriber.respond_to?(:shutdown)
        rescue => error
          warn_failure(error)
        end
      end

      def trace_context(**attributes)
        subscribers.each do |subscriber|
          next unless subscriber.respond_to?(:trace_context)

          context = subscriber.trace_context(**attributes)
          return context unless context.nil? || context.empty?
        rescue => error
          warn_failure(error)
        end
        {}
      end

      private

      def subscribers
        @mutex.synchronize { @subscribers.dup }
      end

      def warn_failure(error)
        @logger.warn("little_ghost instrumentation subscriber failed: #{error.class}")
      rescue
        nil
      end
    end
  end
end
