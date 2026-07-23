# frozen_string_literal: true

module LittleGhost
  RunResult = Data.define(:message, :stop_reason, :usage, :messages, :state) do
    def text
      message&.text.to_s
    end
  end
end
