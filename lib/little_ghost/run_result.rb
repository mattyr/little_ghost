# frozen_string_literal: true

module LittleGhost
  # Associates a validated structured value with its declared schema name.
  StructuredResult = Data.define(:schema_name, :value) # :nodoc:

  # RunResult gives callers one final view of an agent or workflow invocation.
  # It includes the response, usage, updated conversation, state, and any
  # validated structured value.
  #
  # Use #output when the caller should accept either structured or textual
  # agents. It returns the validated structured value when present and #text
  # otherwise.
  RunResult = Data.define(:message, :stop_reason, :usage, :messages, :state, :structured_result) do # :nodoc:
    def initialize(message:, stop_reason:, usage:, messages:, state:, structured_result: nil)
      super
    end

    # Reads the final message text, or an empty string when no message exists.
    def text
      message&.text.to_s
    end

    # Indicates whether the run produced a validated structured result.
    def structured?
      !structured_result.nil?
    end

    # Uses the structured value when present and otherwise #text.
    def output
      structured? ? structured_result.value : text
    end
  end

  # Associates a validated structured value with its declared schema name.
  #
  #   result = LittleGhost::StructuredResult.new(
  #     schema_name: "support_research",
  #     value: {"summary" => "The transfer is still settling."}
  #   )
  #   result.value.fetch("summary") # => "The transfer is still settling."
  class StructuredResult < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(schema_name:, value:) -> StructuredResult
    #
    # Associates +value+ with the schema that validated it.

    ##
    # :attr_reader: schema_name
    # The name declared with <tt>Agent.result_schema</tt>.

    ##
    # :attr_reader: value
    # The locally validated application value.
  end

  # RunResult gives callers one final view of an agent or workflow invocation.
  # It includes the response, usage, updated conversation, state, and any
  # validated structured value.
  #
  # Use #output when the caller should accept either structured or textual
  # agents. It returns the validated structured value when present and #text
  # otherwise.
  class RunResult < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(message:, stop_reason:, usage:, messages:, state:,
    #       structured_result: nil) -> RunResult
    #
    # Creates the terminal value for one agent or workflow invocation.

    ##
    # :attr_reader: message
    # The final assistant Message, or +nil+ when no message was produced.

    ##
    # :attr_reader: stop_reason
    # The normalized reason the terminal model stream stopped.

    ##
    # :attr_reader: usage
    # The Usage accumulated across this invocation.

    ##
    # :attr_reader: messages
    # The complete, updated conversation.

    ##
    # :attr_reader: state
    # The application state at the end of the invocation.

    ##
    # :attr_reader: structured_result
    # The validated StructuredResult, or +nil+ for a textual result.

    ##
    # :method: text
    # Reads the final message text, or an empty string when no message exists.

    ##
    # :method: structured?
    # Indicates whether the invocation produced a validated structured result.

    ##
    # :method: output
    # Uses the structured value when present and otherwise #text.
  end
end
