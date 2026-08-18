# frozen_string_literal: true

module LittleGhost
  ModelResponse = Data.define(:message, :stop_reason, :usage, :metadata) do # :nodoc:
    # Creates an immutable response and coerces +message+ into a Message.
    def initialize(message:, stop_reason:, usage: Usage.new, metadata: {})
      super(
        message: Message.coerce(message),
        stop_reason: stop_reason&.to_sym,
        usage: usage,
        metadata: metadata.freeze
      )
    end
  end

  # Represents the final result shared by every provider stream. It keeps
  # provider-specific response shapes out of the agent loop.
  class ModelResponse < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(message:, stop_reason:, usage: Usage.new, metadata: {}) -> ModelResponse
    #
    # Coerces +message+ to Message, normalizes +stop_reason+ to a Symbol, and
    # freezes the outer +metadata+ Hash.

    ##
    # :attr_reader: message
    # The normalized assistant Message.

    ##
    # :attr_reader: stop_reason
    # The normalized reason the model stopped.

    ##
    # :attr_reader: usage
    # Provider-independent token usage for this response.

    ##
    # :attr_reader: metadata
    # Provider-specific response metadata with a frozen outer Hash. Nested
    # values are retained and must not be mutated by callers.
  end
end
