# frozen_string_literal: true

module LittleGhost
  ToolExecution = Data.define(
    :tool_use,
    :tool,
    :context,
    :events,
    :operation_id,
    :parent_operation_id,
    :parent_trace_context
  )
end
