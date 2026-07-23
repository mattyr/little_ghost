# frozen_string_literal: true

module LittleGhost
  ModelResponse = Data.define(:message, :stop_reason, :usage, :metadata) do
    def initialize(message:, stop_reason:, usage: Usage.new, metadata: {})
      super(
        message: Message.coerce(message),
        stop_reason: stop_reason&.to_sym,
        usage: usage,
        metadata: metadata.freeze
      )
    end
  end
end
