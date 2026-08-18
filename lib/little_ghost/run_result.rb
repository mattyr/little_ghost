# frozen_string_literal: true

module LittleGhost
  # Associates a validated structured value with its declared schema name.
  StructuredResult = Data.define(:schema_name, :value) # :nodoc:

  RunResult = Data.define(:message, :stop_reason, :usage, :messages, :state, :structured_result, :steps) do # :nodoc:
    def initialize(message:, stop_reason:, usage:, messages:, state:, structured_result: nil, steps: [])
      super(message:, stop_reason:, usage:, messages:, state:, structured_result:, steps: Array(steps).freeze)
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

    # Returns immutable coordination queries for this result.
    def trajectory = Assembly::Trajectory.new(steps)
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

  # RunResult gives callers one final view of an Assembly invocation.
  # It includes the response, usage, updated conversation, state, coordination
  # steps, and any validated structured value.
  #
  # Use #output when the caller should accept either structured or textual
  # agents. It returns the validated structured value when present and #text
  # otherwise.
  class RunResult < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(message:, stop_reason:, usage:, messages:, state:,
    #       structured_result: nil, steps: []) -> RunResult
    #
    # Creates the terminal value for one Assembly invocation.

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
    # :attr_reader: steps
    # Immutable Assembly::Step records for composite invocations.

    ##
    # :method: text
    # Reads the final message text, or an empty string when no message exists.

    ##
    # :method: structured?
    # Indicates whether the invocation produced a validated structured result.

    ##
    # :method: output
    # Uses the structured value when present and otherwise #text.

    ##
    # :method: trajectory
    # Returns an Assembly::Trajectory for querying immutable coordination steps.
  end
end
