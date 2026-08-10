# frozen_string_literal: true

module LittleGhost
  # ModelCapabilities tells LittleGhost which optional features a model can use.
  # It keeps structured results and tool selection from relying on provider
  # guesswork.
  #
  # A +nil+ +supported_parameters+ list means parameter support is not restricted.
  # Use +ModelCapabilities.unknown+ when capability metadata is unavailable and
  # callers should avoid assuming support.
  ModelCapabilities = Data.define( # :nodoc:
    :native_structured_output,
    :tools,
    :tool_choice,
    :supported_parameters,
    :known
  ) do
    # Creates an immutable capability description.
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

    # Checks whether any supplied parameter name is supported.
    def supports_parameter?(*names)
      return true unless supported_parameters

      names.flatten.any? { |name| supported_parameters.include?(name.to_s) }
    end

    # Supplies the backwards-compatible capability set for legacy providers.
    def self.legacy
      new(native_structured_output: true, tools: true, tool_choice: true)
    end

    # Marks capability support as unknown.
    def self.unknown
      new(known: false)
    end
  end

  # Describes the optional features a model can use. Providers expose this value
  # so structured results and tool selection do not rely on provider guesswork.
  # A +nil+ supported-parameter list means support is unrestricted.
  class ModelCapabilities < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(native_structured_output: false, tools: false, tool_choice: false,
    #       supported_parameters: nil, known: true) -> ModelCapabilities
    #
    # Normalizes flags to booleans and stores unique parameter-name Strings in a
    # frozen Array.

    ##
    # :attr_reader: native_structured_output
    # Whether the model accepts a provider-native structured-output schema.

    ##
    # :attr_reader: tools
    # Whether the model accepts tool definitions.

    ##
    # :attr_reader: tool_choice
    # Whether the model accepts an explicit tool-selection policy.

    ##
    # :attr_reader: supported_parameters
    # A frozen Array of provider parameter-name Strings, or +nil+ when support is
    # unrestricted. Caller-supplied Strings may be retained rather than copied.

    ##
    # :attr_reader: known
    # Whether this value represents known capability metadata.

    ##
    # :method: native_structured_output?
    # Indicates whether provider-native structured output is available.

    ##
    # :method: tools?
    # Indicates whether the model accepts tools.

    ##
    # :method: tool_choice?
    # Indicates whether the model accepts an explicit tool choice.

    ##
    # :method: known?
    # Indicates whether capability metadata is known.

    ##
    # :method: supports_parameter?
    # :call-seq:
    #   supports_parameter?(*names) -> boolean
    #
    # Checks whether any supplied parameter name is supported. An unrestricted
    # capability set supports every name.

    ##
    # :singleton-method: legacy
    # Supplies the permissive capability set for providers that predate explicit
    # capability reporting.

    ##
    # :singleton-method: unknown
    # Marks capability support as unknown so callers avoid assuming support.
  end
end
