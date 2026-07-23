# frozen_string_literal: true

module LittleGhost
  module Support
    class Callbacks
      Continue = Data.define do
        def continue? = true
        def cancel? = false
        def replace? = false
      end
      CONTINUE = Continue.new.freeze
      Cancel = Data.define(:reason) do
        def continue? = false
        def cancel? = true
        def replace? = false
      end
      Replace = Data.define(:value) do
        def continue? = false
        def cancel? = false
        def replace? = true
      end

      class << self
        def continue = CONTINUE
        def cancel(reason = nil) = Cancel.new(reason:)
        def replace(value) = Replace.new(value:)
      end

      def initialize(*names)
        @callbacks = names.to_h { |name| [name.to_sym, []] }
        @prepend_counts = names.to_h { |name| [name.to_sym, 0] }
      end

      def initialize_copy(source)
        super
        @callbacks = source.instance_variable_get(:@callbacks).transform_values(&:dup)
        @prepend_counts = source.instance_variable_get(:@prepend_counts).dup
      end

      def on(name, callable = nil, prepend: false, &block)
        callback = callable || block
        unless callback.respond_to?(:call) || callback.is_a?(String) || callback.is_a?(Symbol)
          raise ArgumentError, "A callback is required"
        end

        registered = @callbacks.fetch(name.to_sym) { raise ArgumentError, "Unknown callback: #{name}" }
        unless registered.include?(callback)
          if prepend
            registered.unshift(callback)
            @prepend_counts[name.to_sym] += 1
          else
            registered << callback
          end
        end
        self
      end

      def merge(other)
        merged = dup
        other.instance_variable_get(:@callbacks).each do |name, callbacks|
          prepend_count = other.instance_variable_get(:@prepend_counts).fetch(name)
          callbacks.first(prepend_count).reverse_each { |callback| merged.on(name, callback, prepend: true) }
          callbacks.drop(prepend_count).each { |callback| merged.on(name, callback) }
        end
        merged
      end

      def run(name, payload, context: nil, receiver: nil)
        current = payload
        @callbacks.fetch(name.to_sym) { raise ArgumentError, "Unknown callback: #{name}" }.each do |callback|
          decision = normalize(invoke(callback, current, context, receiver))
          case decision
          when Continue
            next
          when Replace
            current = decision.value
          else
            return decision
          end
        end

        current.equal?(payload) ? self.class.continue : self.class.replace(current)
      end

      private

      def invoke(callback, payload, context, receiver)
        callable = if callback.is_a?(String) || callback.is_a?(Symbol)
          raise ArgumentError, "A receiver is required for a named callback" unless receiver

          receiver.method(callback)
        else
          callback
        end
        parameters = callable.respond_to?(:parameters) ? callable.parameters : callable.method(:call).parameters
        accepts_payload = parameters.any? { |kind, _| %i[req opt rest].include?(kind) }
        accepts_context = parameters.any? do |kind, name|
          %i[key keyreq keyrest].include?(kind) && (name == :context || kind == :keyrest)
        end
        arguments = accepts_payload ? [payload] : []
        if receiver && callable.is_a?(Proc)
          accepts_context ? receiver.instance_exec(*arguments, context:, &callable) : receiver.instance_exec(*arguments, &callable)
        else
          accepts_context ? callable.call(*arguments, context:) : callable.call(*arguments)
        end
      end

      def normalize(decision)
        return decision if decision.is_a?(Continue) || decision.is_a?(Cancel) || decision.is_a?(Replace)

        self.class.continue
      end
    end
  end
end
