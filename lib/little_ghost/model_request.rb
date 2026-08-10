# frozen_string_literal: true

module LittleGhost
  # ModelRequest carries everything a provider needs for one model stream. It
  # keeps messages, tools, settings, structured-output requirements, and
  # cooperative execution controls together.
  #
  # Messages are coerced into Message objects, and required capabilities are
  # normalized to unique symbols. The messages, tools, settings, and capability
  # containers are frozen; output schema and tool choice values are retained as
  # supplied.
  #
  # Only those outer containers are frozen. Do not mutate retained output
  # schemas, tool choices, or nested settings after construction, and do not
  # share mutable control values across concurrent requests.
  ModelRequest = Data.define( # :nodoc:
    :messages,
    :tools,
    :settings,
    :output_schema,
    :tool_choice,
    :required_capabilities,
    :cancellation_token,
    :deadline
  ) do
    # Creates a model request with optional tools, structured output, tool choice,
    # cancellation, and deadline controls.
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

  # Carries everything a provider needs for one model stream. Messages are
  # normalized to Message objects, and required capabilities become unique
  # symbols. The main request containers are frozen, but nested values are not
  # defensively copied.
  #
  # Treat settings, output schemas, and tool-choice values as immutable after
  # construction. Create a separate copy before using mutable control data in
  # another request or thread.
  class ModelRequest < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(messages:, tools: [], settings: {}, output_schema: nil,
    #       tool_choice: nil, required_capabilities: [],
    #       cancellation_token: Support::CancellationToken.new,
    #       deadline: nil) -> ModelRequest
    #
    # Creates one normalized provider request with cooperative cancellation and
    # deadline controls. Freezing is shallow; retained nested control values must
    # not be mutated afterward.

    ##
    # :attr_reader: messages
    # The normalized conversation in a frozen Array.

    ##
    # :attr_reader: tools
    # The model-visible tool specifications in a frozen Array.

    ##
    # :attr_reader: settings
    # Trusted provider settings in the caller's now-frozen Hash. Nested values
    # remain mutable and must not change after construction.

    ##
    # :attr_reader: output_schema
    # The requested structured-output schema, or +nil+ for ordinary text. The
    # caller-owned value is retained and must not be mutated afterward.

    ##
    # :attr_reader: tool_choice
    # The requested tool-selection policy, when one applies. The caller-owned
    # value is retained and must not be mutated afterward.

    ##
    # :attr_reader: required_capabilities
    # The normalized capabilities the selected model must support.

    ##
    # :attr_reader: cancellation_token
    # The cooperative cancellation token shared with the provider.

    ##
    # :attr_reader: deadline
    # The absolute request deadline, or +nil+ when none was configured.
  end
end
