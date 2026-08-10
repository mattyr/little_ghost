# frozen_string_literal: true

module LittleGhost
  # ToolExecution gives runtime hooks one complete view of a tool call. It keeps
  # the tool, call, run context, emitted events, and tracing relationship
  # together while hooks prepare or observe execution.
  #
  # +events+ collects events emitted around the execution, while operation IDs
  # and trace context relate nested tool work to its parent operation.
  ToolExecution = Data.define( # :nodoc:
    :tool_use,
    :tool,
    :context,
    :events,
    :operation_id,
    :parent_operation_id,
    :parent_trace_context
  )

  # Gives runtime hooks one complete view of a tool call while they prepare or
  # observe its execution.
  class ToolExecution < Data # :doc:
    ##
    # :singleton-method: new
    # :call-seq:
    #   new(tool_use:, tool:, context:, events:, operation_id:,
    #       parent_operation_id:, parent_trace_context:) -> ToolExecution
    #
    # Collects one bound tool call for runtime hooks.

    ##
    # :attr_reader: tool_use
    # The Content::ToolUse requested by the model.

    ##
    # :attr_reader: tool
    # The bound Tool instance selected for the call.

    ##
    # :attr_reader: context
    # The cooperative RunContext for this work.

    ##
    # :attr_reader: events
    # Events collected around the tool execution.

    ##
    # :attr_reader: operation_id
    # The instrumentation operation identifier for this call.

    ##
    # :attr_reader: parent_operation_id
    # The parent instrumentation operation identifier, when present.

    ##
    # :attr_reader: parent_trace_context
    # The trace context inherited from the parent operation, when present.
  end
end
