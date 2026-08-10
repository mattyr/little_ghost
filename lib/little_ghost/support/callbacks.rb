# frozen_string_literal: true

module LittleGhost
  module Support
    # Callbacks lets extensions prepare, replace, or cancel framework work in a
    # predictable order. A later callback sees any replacement made earlier in
    # the chain.
    #
    # A callback may return Callbacks.continue, Callbacks.cancel, or
    # Callbacks.replace. Any other return value means continue. Replacements
    # become the payload for later callbacks.
    #
    # Every decision responds to +continue?+, +cancel?+, and +replace?+. A
    # cancellation also exposes +reason+; a replacement exposes +value+.
    # Extensions should depend on these methods rather than a decision's
    # concrete class.
    #
    #   callbacks = LittleGhost::Support::Callbacks.new(:prepare)
    #   callbacks.on(:prepare) { |payload| Callbacks.replace(payload.merge(debug: true)) }
    #   decision = callbacks.run(:prepare, {})
    #   decision.value # => {debug: true}
    class Callbacks
      Continue = Data.define do # :nodoc:
        def continue? = true
        def cancel? = false
        def replace? = false
      end
      CONTINUE = Continue.new.freeze # :nodoc:
      Cancel = Data.define(:reason) do # :nodoc:
        def continue? = false
        def cancel? = true
        def replace? = false
      end
      Replace = Data.define(:value) do # :nodoc:
        def continue? = false
        def cancel? = false
        def replace? = true
      end

      class << self
        # Uses the shared decision whose +continue?+ predicate indicates that
        # callback processing should proceed.
        def continue = CONTINUE

        # Creates a decision whose +cancel?+ predicate indicates that callback
        # processing should stop. The returned value exposes the optional
        # +reason+.
        def cancel(reason = nil) = Cancel.new(reason:)

        # Creates a decision whose +replace?+ predicate indicates that later
        # callbacks should receive +value+.
        def replace(value) = Replace.new(value:)
      end

      # Starts an empty chain for the declared callback +names+.
      def initialize(*names)
        @callbacks = names.to_h { |name| [name.to_sym, []] }
        @prepend_counts = names.to_h { |name| [name.to_sym, 0] }
      end

      # Duplicates callback arrays so subclasses and instances can extend a copy.
      def initialize_copy(source)
        super
        @callbacks = source.instance_variable_get(:@callbacks).transform_values(&:dup)
        @prepend_counts = source.instance_variable_get(:@prepend_counts).dup
      end

      # Registers a callable, block, or receiver method name for +name+.
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

      # Combines this chain with +other+ while
      # preserving prepend ordering.
      def merge(other)
        merged = dup
        other.instance_variable_get(:@callbacks).each do |name, callbacks|
          prepend_count = other.instance_variable_get(:@prepend_counts).fetch(name)
          callbacks.first(prepend_count).reverse_each { |callback| merged.on(name, callback, prepend: true) }
          callbacks.drop(prepend_count).each { |callback| merged.on(name, callback) }
        end
        merged
      end

      # Runs +name+ until callbacks finish or one cancels the chain.
      #
      # The returned decision responds to +continue?+, +cancel?+, and
      # +replace?+. Cancellation decisions expose +reason+, while replacement
      # decisions expose the final +value+.
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
