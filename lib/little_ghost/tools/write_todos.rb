# frozen_string_literal: true

module LittleGhost
  module Tools
    class WriteTodos < Tool
      tool_name "write_todos"
      description <<~DESCRIPTION.strip
        Replace the plan for meaningful multi-step work. Skip this for simple requests. Give the plan and every todo a
        short user-facing title. Put longer private working notes in details. Publish the full list before substantive
        work, allow at most one in-progress step, and replace the full list as work progresses. Preserve IDs for todos
        that remain, update titles and statuses in place, never reuse an ID for a different todo, and remove todos that
        no longer apply. Complete every remaining todo before the final response; use an empty list when no plan remains.
      DESCRIPTION
      input_schema(
        type: "object",
        properties: {
          plan_title: {type: "string", minLength: 1, maxLength: 80, pattern: "^[^\\x00-\\x1f\\x7f]+$"},
          todos: {
            type: "array",
            maxItems: 20,
            items: {
              type: "object",
              properties: {
                id: {type: "string", minLength: 1, maxLength: 64, pattern: "^[a-z0-9][a-z0-9_-]*$"},
                title: {type: "string", minLength: 1, maxLength: 48, pattern: "^[^\\x00-\\x1f\\x7f]+$"},
                status: {type: "string", enum: %w[pending in_progress completed]},
                details: {type: ["string", "null"], maxLength: 4_000}
              },
              required: %w[id title status],
              additionalProperties: false
            }
          }
        },
        required: %w[plan_title todos],
        additionalProperties: false
      )

      def execute(input, context: nil)
        super(normalize_titles(input), context:)
      end

      def call(input, context:)
        todos = input.fetch("todos")
        raise ToolError, "only one todo may be in progress" if todos.count { |todo| todo["status"] == "in_progress" } > 1

        ids = todos.map { |todo| todo.fetch("id") }
        raise ToolError, "todo IDs must be unique" unless ids.uniq.length == ids.length

        state = context ? (context.state["little_ghost.plan"] ||= empty_plan) : (@fallback_state ||= empty_plan)
        state.replace("plan_title" => input.fetch("plan_title"), "todos" => todos.map(&:dup))
        state.dup
      end

      private

      def normalize_titles(input)
        return input unless input.is_a?(Hash)

        normalized = input.dup
        normalized["plan_title"] = normalized["plan_title"].strip if normalized["plan_title"].is_a?(String)
        if normalized["todos"].is_a?(Array)
          normalized["todos"] = normalized["todos"].map do |todo|
            next todo unless todo.is_a?(Hash)

            todo = todo.dup
            todo["title"] = todo["title"].strip if todo["title"].is_a?(String)
            todo
          end
        end
        normalized
      end

      def empty_plan
        {"plan_title" => nil, "todos" => []}
      end
    end
  end
end
