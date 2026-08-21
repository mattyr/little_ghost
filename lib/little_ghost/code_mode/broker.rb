# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  module CodeMode
    # Keeps tool authorization and execution in the trusted parent process.
    class Broker
      # Builds a broker for an Agent's Tool registry. +except+ removes names from
      # the code-mode catalog. +dispatch+ is a trusted adapter hook used by
      # custom hosts; ordinary Agent integrations should let the broker dispatch
      # through +agent+.
      def initialize(agent: nil, registry: nil, context: RunContext.new, events: [],
        parent_operation_id: nil, parent_trace_context: nil, except: nil, dispatch: nil, max_calls: nil)
        @agent = agent
        runtime = agent&.runtime
        @task_runner = runtime ? runtime.task_runner : Support::TaskRunner.new
        @registry = registry || agent&.tool_registry
        @context = context
        @events = events
        @parent_operation_id = parent_operation_id
        @parent_trace_context = parent_trace_context
        @except = Array(except).map(&:to_s).freeze
        @dispatch = dispatch
        @max_calls = max_calls && Integer(max_calls)
        @call_count = 0
        @call_mutex = Mutex.new
        @delivery_mutex = Mutex.new
        @presentation_content = []
        @artifacts = []
        @fallback_references = []
        @presentation_budget = Artifacts::PresentationBudget.new
      end

      # Returns the Tool specifications available to model-authored code.
      # Excluded Tools, code-mode controls, and subagent controls stay outside
      # this catalog.
      def catalog
        specifications = @registry&.specifications || []
        specifications.reject do |specification|
          name = specification.fetch(:name, specification["name"]).to_s
          tool = @registry.fetch(name)
          @except.include?(name) || %w[exec wait stop].include?(name) || subagent_control?(tool)
        end
      end

      attr_writer :context # :nodoc:

      attr_reader :task_runner # :nodoc:

      def bind(context:, events:, parent_operation_id:, parent_trace_context: nil) # :nodoc:
        @context = context
        @events = events
        @parent_operation_id = parent_operation_id
        @parent_trace_context = parent_trace_context
        self
      end

      # Calls an available Tool by model-visible +name+. The returned CallResult
      # has +id+, decoded +value+, and model-safe +error+ fields. +arguments+
      # remains untrusted until the ordinary Tool path validates and authorizes
      # it.
      def call(name, arguments = {}, id: SecureRandom.uuid)
        @call_mutex.synchronize do
          @call_count += 1
          raise ToolError, "Code-mode tool call budget exceeded" if @max_calls && @call_count > @max_calls
        end
        name = String(name).delete_prefix("tools.")
        available = catalog.any? { |specification| specification.fetch(:name, specification["name"]).to_s == name }
        raise ToolError, "Tool is not available in code mode: #{name}" unless available
        raise ToolError, "Tool arguments must be an object" unless arguments.is_a?(Hash)

        execution_result = nil
        result = if @dispatch
          dispatched = @dispatch.call(Call.new(id:, name:, arguments:))
          if dispatched.respond_to?(:presentation_content) && dispatched.respond_to?(:artifacts)
            record_delivery(dispatched.presentation_content, dispatched.artifacts)
          end
          dispatched
        elsif @agent
          use = Content::ToolUse.new(id:, name:, input: arguments)
          emit_brokered_tool_call(use)
          executed = @agent.dispatch_tools(
            [use],
            context: @context,
            events: @events,
            parent_operation_id: @parent_operation_id,
            parent_trace_context: @parent_trace_context
          ).first
          record_delivery(executed.presentation_content, executed.artifacts)
          execution_result = executed.execution_result
        else
          tool = @registry.fetch(name)
          execution = tool.execute(arguments, context: @context)
          record_delivery(execution.presentation_content, execution.artifacts)
          return CallResult.new(id:, value: execution.value, error: execution.error? ? execution.content : nil)
        end

        return result if result.is_a?(CallResult)

        execution_result ||= result
        content = execution_result.respond_to?(:content) ? execution_result.content : execution_result
        value = execution_result.respond_to?(:value) ? execution_result.value : decode(content)
        status = execution_result.respond_to?(:status) ? execution_result.status : :success
        CallResult.new(id:, value:, error: (content if status == :error))
      rescue ToolError => error
        CallResult.new(id:, value: nil, error: error.message)
      end

      def drain_delivery # :nodoc:
        @delivery_mutex.synchronize do
          delivery = [@presentation_content.freeze, @artifacts.freeze, @fallback_references.uniq.freeze]
          @presentation_content = []
          @artifacts = []
          @fallback_references = []
          @presentation_budget = Artifacts::PresentationBudget.new
          delivery
        end
      end

      private

      def subagent_control?(tool)
        defined?(Subagents::ControlTool) && tool.is_a?(Subagents::ControlTool)
      end

      def emit_brokered_tool_call(tool_use)
        return unless @events.respond_to?(:<<)

        @events << StreamEvent.build(:tool_call_start, index: 0, id: tool_use.id, name: tool_use.name)
        @events << StreamEvent.build(:tool_call_delta, index: 0, arguments: JSON.generate(tool_use.input))
        @events << StreamEvent.build(:tool_call_stop, index: 0, tool_use:)
      end

      def record_delivery(presentations, artifacts)
        return if presentations.empty? && artifacts.empty?

        @delivery_mutex.synchronize do
          accepted = @presentation_budget.accept(presentations)
          @presentation_content.concat(accepted)
          @artifacts.concat(artifacts)
          if accepted.empty? && artifacts.any?
            @fallback_references.concat(artifact_references(artifacts))
          end
        end
      end

      def artifact_references(artifacts)
        artifacts.filter_map do |artifact|
          next if artifact.metadata[:complete_result] || artifact.metadata["complete_result"]
          next unless artifact.reference.is_a?(String) && artifact.bytes

          details = [artifact.media_type, "#{artifact.bytes} bytes"].compact.join(", ")
          "- #{artifact.reference} (#{details})"
        end
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
