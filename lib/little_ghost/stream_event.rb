# frozen_string_literal: true

module LittleGhost
  StreamEvent = Data.define(:type, :data) do
    def self.build(type, **data)
      new(type: type.to_sym, data: data.freeze)
    end
  end
end
