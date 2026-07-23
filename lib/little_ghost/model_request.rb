# frozen_string_literal: true

module LittleGhost
  ModelRequest = Data.define(:messages, :tools, :settings, :cancellation_token, :deadline) do
    def initialize(messages:, tools: [], settings: {}, cancellation_token: Support::CancellationToken.new, deadline: nil)
      super(
        messages: messages.map { |message| Message.coerce(message) }.freeze,
        tools: tools.freeze,
        settings: settings.freeze,
        cancellation_token: cancellation_token,
        deadline:
      )
    end
  end
end
