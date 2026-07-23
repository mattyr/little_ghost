# frozen_string_literal: true

require "opentelemetry-api"

module LittleGhost
  module Tracing
    class OpenTelemetry
      ATTRIBUTE_NAMES = {
        agent_id: "gen_ai.agent.name",
        model_id: "gen_ai.request.model",
        model_provider: "gen_ai.provider.name",
        input_tokens: "gen_ai.usage.input_tokens",
        output_tokens: "gen_ai.usage.output_tokens",
        total_tokens: "gen_ai.usage.total_tokens",
        cache_read_tokens: "gen_ai.usage.cache_read_input_tokens",
        cache_write_tokens: "gen_ai.usage.cache_write_input_tokens",
        reasoning_tokens: "gen_ai.usage.reasoning_tokens",
        time_to_first_token: "gen_ai.server.time_to_first_token",
        available_tools: "gen_ai.agent.tools",
        session_id: "session.id",
        tool_name: "gen_ai.tool.name",
        diagnostic_input: "input.value",
        diagnostic_output: "output.value"
      }.freeze
      OPENINFERENCE_ATTRIBUTE_NAMES = {
        agent_id: "agent.name",
        model_id: "llm.model_name",
        model_provider: "llm.provider",
        input_tokens: "llm.token_count.prompt",
        output_tokens: "llm.token_count.completion",
        total_tokens: "llm.token_count.total",
        cache_read_tokens: "llm.token_count.prompt_details.cache_read",
        cache_write_tokens: "llm.token_count.prompt_details.cache_write",
        reasoning_tokens: "llm.token_count.completion_details.reasoning",
        tool_name: "tool.name"
      }.freeze
      GENERIC_USAGE_ATTRIBUTES = %i[total_tokens cache_read_tokens cache_write_tokens reasoning_tokens].freeze
      OPERATIONS = {
        agent: "invoke_agent",
        model: "chat",
        run: "invoke_agent",
        subagent: "invoke_agent",
        tool: "execute_tool"
      }.freeze
      CONTENT_KEYS = %w[arguments content input input_text message output output_text prompt response text].freeze
      SENSITIVE_KEY = /(authorization|api[_-]?key|credential|password|secret|(?:^|[_-])token(?:$|[_-])|cookie|private[_-]?key)/i
      MAX_ATTRIBUTE_LENGTH = 1_024

      def initialize(tracer: nil)
        @tracer = tracer
        @spans = {}
        @mutex = Mutex.new
      end

      def call(name, attributes)
        operation_id = attributes[:operation_id]
        if name.to_s.end_with?("_start") && operation_id
          start_span(name, attributes)
        elsif name.to_s.end_with?("_stop") && operation_id
          finish_span(attributes)
        else
          add_event(name, attributes)
        end
      end

      def trace_context(operation_id: nil, **)
        span = @mutex.synchronize { @spans[operation_id] }
        context = span&.context
        return {} unless context&.valid?

        carrier = {}
        ::OpenTelemetry.propagation.inject(
          carrier,
          context: ::OpenTelemetry::Trace.context_with_span(span)
        )
        carrier.slice("traceparent", "tracestate").merge(trace_id: context.hex_trace_id)
      rescue
        context&.valid? ? {trace_id: context.hex_trace_id} : {}
      end

      def flush
        provider = ::OpenTelemetry.tracer_provider
        provider.force_flush if provider.respond_to?(:force_flush)
      end

      def shutdown
        spans = @mutex.synchronize do
          current = @spans.values
          @spans = {}
          current
        end
        spans.each(&:finish)
      end

      private

      def tracer
        @tracer || ::OpenTelemetry.tracer_provider.tracer("little_ghost", LittleGhost::VERSION)
      end

      def start_span(name, attributes)
        kind = name.to_s.delete_suffix("_start").to_sym
        parent = @mutex.synchronize { @spans[attributes[:parent_operation_id]] }
        parent_context = if parent
          ::OpenTelemetry::Trace.context_with_span(parent)
        elsif attributes[:trace_context].is_a?(Hash)
          ::OpenTelemetry.propagation.extract(attributes[:trace_context])
        end
        span = tracer.start_span(
          span_name(kind, attributes),
          with_parent: parent_context,
          attributes: span_attributes(attributes).merge(
            "gen_ai.operation.name" => OPERATIONS.fetch(kind, kind.to_s),
            "openinference.span.kind" => openinference_kind(kind)
          )
        )
        @mutex.synchronize { @spans[attributes.fetch(:operation_id)] = span }
      end

      def finish_span(attributes)
        span = @mutex.synchronize { @spans.delete(attributes[:operation_id]) }
        return add_event(:orphan_stop, attributes) unless span

        span_attributes(attributes).each { |key, value| span.set_attribute(key, value) }
        if attributes[:outcome].to_s == "error" || attributes[:error_class]
          span.status = ::OpenTelemetry::Trace::Status.error(attributes[:error_class].to_s)
        end
        span.finish
      end

      def add_event(name, attributes)
        owner_id = attributes[:parent_operation_id] || attributes[:operation_id]
        span = @mutex.synchronize { @spans[owner_id] }
        if span
          span.add_event("little_ghost.#{name}", attributes: span_attributes(attributes))
        else
          tracer.in_span("little_ghost.#{name}", attributes: span_attributes(attributes)) {}
        end
      end

      def span_name(kind, attributes)
        detail = case kind
        when :agent then attributes[:agent_id]
        when :model then attributes[:model_id]
        when :subagent then attributes[:kind]
        when :tool then attributes[:tool_name]
        end
        detail = attribute_value(:span_name, detail) if detail
        [OPERATIONS.fetch(kind, kind.to_s), detail].compact.join(" ")
      end

      def span_attributes(attributes)
        attributes.each_with_object({}) do |(key, value), result|
          next if %i[operation_id parent_operation_id trace_context].include?(key)

          name = if key.to_s.include?(".")
            key.to_s
          else
            ATTRIBUTE_NAMES.fetch(key.to_sym, "little_ghost.#{key}")
          end
          normalized = attribute_value(key, value)
          result[name] = gen_ai_usage_value(key, attributes, normalized)
          openinference_name = OPENINFERENCE_ATTRIBUTE_NAMES[key.to_sym]
          result[openinference_name] = openinference_usage_value(key, attributes, normalized) if openinference_name
          result["little_ghost.#{key}"] = normalized if GENERIC_USAGE_ATTRIBUTES.include?(key.to_sym)
          if %i[diagnostic_input diagnostic_output].include?(key.to_sym)
            result["#{name.delete_suffix(".value")}.mime_type"] = "application/json"
          end
        end.tap { |result| add_available_tools(result, attributes[:available_tools]) }
      end

      def add_available_tools(attributes, tools)
        Array(tools).each_with_index do |name, index|
          attributes["llm.tools.#{index}.tool.name"] = scalar(name)
        end
      end

      def openinference_kind(kind)
        {agent: "AGENT", run: "CHAIN", subagent: "AGENT", model: "LLM", tool: "TOOL"}.fetch(kind, "CHAIN")
      end

      def openinference_usage_value(key, attributes, value)
        return value.to_i + attributes.fetch(:cache_read_tokens, 0).to_i + attributes.fetch(:cache_write_tokens, 0).to_i if key.to_sym == :input_tokens
        return value.to_i + attributes.fetch(:reasoning_tokens, 0).to_i if key.to_sym == :output_tokens

        value
      end

      def gen_ai_usage_value(key, attributes, value)
        return value.to_i + attributes.fetch(:cache_read_tokens, 0).to_i + attributes.fetch(:cache_write_tokens, 0).to_i if key.to_sym == :input_tokens
        return value.to_i + attributes.fetch(:reasoning_tokens, 0).to_i if key.to_sym == :output_tokens

        value
      end

      def attribute_value(key, value)
        return value if key.to_sym == :time_to_first_token && value.is_a?(Numeric)

        key_name = key.to_s
        normalized_key = key_name.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
        return "[REDACTED]" if SENSITIVE_KEY.match?(normalized_key) || CONTENT_KEYS.include?(normalized_key)

        case value
        when String
          limit = key.to_s.start_with?("diagnostic_") ? value.length : MAX_ATTRIBUTE_LENGTH
          value.slice(0, limit)
        when Symbol then value.to_s
        when Numeric, true, false then value
        when Array then value.filter_map { |item| scalar(item) }
        else value.to_s.slice(0, MAX_ATTRIBUTE_LENGTH)
        end
      end

      def scalar(value)
        case value
        when String then value.slice(0, MAX_ATTRIBUTE_LENGTH)
        when Symbol then value.to_s
        when Numeric, true, false then value
        end
      end
    end
  end
end
