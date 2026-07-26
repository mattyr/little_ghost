# frozen_string_literal: true

module LittleGhost
  ModelCapabilities = Data.define(
    :native_structured_output,
    :tools,
    :tool_choice,
    :supported_parameters,
    :known
  ) do
    def initialize(
      native_structured_output: false,
      tools: false,
      tool_choice: false,
      supported_parameters: nil,
      known: true
    )
      parameters = supported_parameters&.map(&:to_s)&.uniq&.freeze
      super(
        native_structured_output: !!native_structured_output,
        tools: !!tools,
        tool_choice: !!tool_choice,
        supported_parameters: parameters,
        known: !!known
      )
    end

    def native_structured_output? = native_structured_output
    def tools? = tools
    def tool_choice? = tool_choice
    def known? = known

    def supports_parameter?(*names)
      return true unless supported_parameters

      names.flatten.any? { |name| supported_parameters.include?(name.to_s) }
    end

    def self.legacy
      new(native_structured_output: true, tools: true, tool_choice: true)
    end

    def self.unknown
      new(known: false)
    end
  end
end
