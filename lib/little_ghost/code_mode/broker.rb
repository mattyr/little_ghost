# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  module CodeMode
    # Keeps tool authorization and execution in the trusted parent process.
    class Broker
      def initialize(agent: nil, registry: nil, context: RunContext.new, events: [],
        parent_operation_id: nil, parent_trace_context: nil, direct_tools: nil, dispatch: nil, max_calls: nil)
        @agent = agent
        @registry = registry || agent&.tool_registry
        @context = context
        @events = events
        @parent_operation_id = parent_operation_id
        @parent_trace_context = parent_trace_context
        @direct_tools = Array(direct_tools).map(&:to_s).freeze
        @dispatch = dispatch
        @max_calls = max_calls && Integer(max_calls)
        @call_count = 0
        @call_mutex = Mutex.new
      end

      def catalog
        specifications = @registry&.specifications || []
        specifications.reject do |specification|
          name = specification.fetch(:name, specification["name"]).to_s
          @direct_tools.include?(name) || %w[exec wait].include?(name)
        end
      end

      attr_writer :context # :nodoc:

      def bind(context:, events:, parent_operation_id:, parent_trace_context: nil) # :nodoc:
        @context = context
        @events = events
        @parent_operation_id = parent_operation_id
        @parent_trace_context = parent_trace_context
        self
      end

      def call(name, arguments = {}, id: SecureRandom.uuid)
        @call_mutex.synchronize do
          @call_count += 1
          raise ToolError, "Code-mode tool call budget exceeded" if @max_calls && @call_count > @max_calls
        end
        name = String(name)
        available = catalog.any? { |specification| specification.fetch(:name, specification["name"]).to_s == name }
        raise ToolError, "Tool is not available in code mode: #{name}" unless available
        raise ToolError, "Tool arguments must be an object" unless arguments.is_a?(Hash)

        result = if @dispatch
          @dispatch.call(Call.new(id:, name:, arguments:))
        elsif @agent
          use = Content::ToolUse.new(id:, name:, input: arguments)
          emit_brokered_tool_call(use)
          @agent.dispatch_tools(
            [use],
            context: @context,
            events: @events,
            parent_operation_id: @parent_operation_id,
            parent_trace_context: @parent_trace_context
          ).first.result
        else
          tool = @registry.fetch(name)
          execution = tool.execute(arguments, context: @context)
          return CallResult.new(id:, value: decode(execution.content), error: execution.error? ? execution.content : nil)
        end

        return result if result.is_a?(CallResult)

        content = result.respond_to?(:content) ? result.content : result
        status = result.respond_to?(:status) ? result.status : :success
        CallResult.new(id:, value: decode(content), error: (content if status == :error))
      rescue ToolError => error
        CallResult.new(id:, value: nil, error: error.message)
      end

      private

      def emit_brokered_tool_call(tool_use)
        return unless @events.respond_to?(:<<)

        @events << StreamEvent.build(:tool_call_start, index: 0, id: tool_use.id, name: tool_use.name)
        @events << StreamEvent.build(:tool_call_delta, index: 0, arguments: JSON.generate(tool_use.input))
        @events << StreamEvent.build(:tool_call_stop, index: 0, tool_use:)
      end

      def decode(value)
        return value unless value.is_a?(String)

        JSON.parse(value)
      rescue JSON::ParserError
        value
      end
    end
  end
end
