# frozen_string_literal: true

module LittleGhost
  ModelRequest = Data.define(:messages, :tools, :settings, :output_schema, :cancellation_token, :deadline) do
    def initialize(
      messages:,
      tools: [],
      settings: {},
      output_schema: nil,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil
    )
      super(
        messages: messages.map { |message| Message.coerce(message) }.freeze,
        tools: tools.freeze,
        settings: settings.freeze,
        output_schema: output_schema && Support.immutable(output_schema),
        cancellation_token: cancellation_token,
        deadline:
      )
    end
  end
end
