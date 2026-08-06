# frozen_string_literal: true

module LittleGhost
  ModelRequest = Data.define(
    :messages,
    :tools,
    :settings,
    :output_schema,
    :tool_choice,
    :required_capabilities,
    :cancellation_token,
    :deadline
  ) do
    def initialize(
      messages:,
      tools: [],
      settings: {},
      output_schema: nil,
      tool_choice: nil,
      required_capabilities: [],
      cancellation_token: Support::CancellationToken.new,
      deadline: nil
    )
      super(
        messages: messages.map { |message| Message.coerce(message) }.freeze,
        tools: tools.freeze,
        settings: settings.freeze,
        output_schema:,
        tool_choice:,
        required_capabilities: required_capabilities.map(&:to_sym).uniq.freeze,
        cancellation_token: cancellation_token,
        deadline:
      )
    end
  end
end
