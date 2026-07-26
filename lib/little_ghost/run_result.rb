# frozen_string_literal: true

module LittleGhost
  StructuredResult = Data.define(:schema_name, :value)

  RunResult = Data.define(:message, :stop_reason, :usage, :messages, :state, :structured_result) do
    def initialize(message:, stop_reason:, usage:, messages:, state:, structured_result: nil)
      super
    end

    def text
      message&.text.to_s
    end

    def structured?
      !structured_result.nil?
    end

    def output
      structured? ? structured_result.value : text
    end
  end
end
