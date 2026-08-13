# frozen_string_literal: true

require "json"
require "opentelemetry-api"

module LittleGhost
  # Optional adapters for sending LittleGhost instrumentation to tracing tools.
  module Tracing
    # OpenTelemetry turns LittleGhost lifecycle notifications into GenAI spans and
    # events. It brings agents, model calls, tools, workflows, and token usage into
    # the same traces as the rest of an application.
    #
    #   LittleGhost.configure do |config|
    #     config.instrument LittleGhost::Tracing::OpenTelemetry.new
    #   end
    #
    # LittleGhost depends only on +opentelemetry-api+. Install and configure the
    # desired SDK, processors, and exporters before registering this subscriber.
    #
    # === Content and trust
    #
    # Prompts, responses, messages, tool arguments, and exception content are
    # omitted by default. They appear only when Instrumentation has an explicit,
    # scrubbed Support::ContentCapture policy.
    class OpenTelemetry < Instrumentation::Subscriber
      ATTRIBUTE_NAMES = {
        agent_id: "gen_ai.agent.id",
        agent_name: "gen_ai.agent.name",
        model_id: "gen_ai.request.model",
        model_provider: "gen_ai.provider.name",
        response_id: "gen_ai.response.id",
        response_model: "gen_ai.response.model",
        finish_reasons: "gen_ai.response.finish_reasons",
        input_tokens: "gen_ai.usage.input_tokens",
        output_tokens: "gen_ai.usage.output_tokens",
        cache_read_tokens: "gen_ai.usage.cache_read.input_tokens",
        cache_write_tokens: "gen_ai.usage.cache_creation.input_tokens",
        reasoning_tokens: "gen_ai.usage.reasoning.output_tokens",
        time_to_first_token: "gen_ai.response.time_to_first_chunk",
        session_id: "gen_ai.conversation.id",
        tool_name: "gen_ai.tool.name",
        tool_type: "gen_ai.tool.type",
        tool_call_id: "gen_ai.tool.call.id",
        workflow_name: "gen_ai.workflow.name",
        assembly_id: "little_ghost.assembly.id",
        assembly_kind: "little_ghost.assembly.kind",
        http_response_status_code: "http.response.status_code",
        error_class: "error.type",
        error_type: "error.type"
      }.freeze # :nodoc:
      OPERATIONS = {
        agent: "invoke_agent",
        agent_turn: "agent_turn",
        model: "chat",
        run: "invoke_agent",
        runtime: "runtime_startup",
        session_store: "session_store",
        subagent: "invoke_agent",
        assembly_step: "execute_assembly_step",
        tool: "execute_tool",
        workflow: "invoke_workflow",
        swarm: "invoke_swarm",
        graph: "invoke_graph",
        assembly: "invoke_assembly"
      }.freeze # :nodoc:
      REQUEST_SETTING_ATTRIBUTES = {
        frequency_penalty: "gen_ai.request.frequency_penalty",
        max_tokens: "gen_ai.request.max_tokens",
        max_output_tokens: "gen_ai.request.max_tokens",
        presence_penalty: "gen_ai.request.presence_penalty",
        seed: "gen_ai.request.seed",
        temperature: "gen_ai.request.temperature",
        top_k: "gen_ai.request.top_k",
        top_p: "gen_ai.request.top_p"
      }.freeze # :nodoc:
      CONTENT_KEYS = %w[arguments content input input_text message output output_text prompt response text].freeze # :nodoc:
      SENSITIVE_KEY = /(authorization|api[_-]?key|credential|password|secret|(?:^|[_-])token(?:$|[_-])|cookie|private[_-]?key)/i # :nodoc:
      MAX_ATTRIBUTE_LENGTH = 1_024 # :nodoc:

      # Uses +tracer+ or the global tracer provider.
      def initialize(tracer: nil)
        @tracer = tracer
        @entries = {}
        @mutex = Mutex.new
      end

      # Starts a span for a lifecycle operation.
      def start(name, attributes)
        start_span(name.to_sym, prepare_attributes(:start, name.to_sym, attributes))
      end

      # Finishes the span correlated by operation ID.
      def finish(name, attributes)
        finish_span(name.to_sym, prepare_attributes(:finish, name.to_sym, attributes))
      end

      # Adds a structured event to the correlated active span.
      def emit(name, attributes)
        add_event(name.to_sym, prepare_attributes(:emit, name.to_sym, attributes))
      end

      # Supplies W3C propagation fields for an active operation when known.
      def trace_context(operation_id: nil, **)
        span = @mutex.synchronize { @entries.dig(operation_id, :span) }
        context = span&.context
        return {} unless context&.valid?

        carrier = {}
        trace_context_propagator.inject(
          carrier,
          context: ::OpenTelemetry::Trace.context_with_span(span)
        )
        carrier.slice("traceparent", "tracestate").merge(trace_id: context.hex_trace_id)
      rescue
        context&.valid? ? {trace_id: context.hex_trace_id} : {}
      end

      # Wraps a block in a standalone internal span. Prefer lifecycle
      # Instrumentation methods for normal framework operations.
      def with_span(name, attributes:, parent_operation_id: nil)
        parent = @mutex.synchronize { @entries[parent_operation_id] }
        parent_context = parent && ::OpenTelemetry::Trace.context_with_span(parent.fetch(:span))
        options = {kind: :internal, attributes:}
        options[:with_parent] = parent_context if parent_context
        span = tracer.start_span(name, **options)
        yield span
      rescue => error
        span.status = ::OpenTelemetry::Trace::Status.error(error.class.name) if span
        raise
      ensure
        span&.finish
      end

      # Flushes through the configured tracer provider when supported.
      def flush(timeout: nil)
        provider = ::OpenTelemetry.tracer_provider
        provider.force_flush(timeout:) if provider.respond_to?(:force_flush)
      end

      # Finishes spans still owned by this subscriber.
      def shutdown(timeout: nil)
        spans = @mutex.synchronize do
          current = @entries.values.map { |entry| entry.fetch(:span) }.uniq
          @entries = {}
          current
        end
        spans.each(&:finish)
      end

      private

      def prepare_attributes(_phase, _name, attributes) = attributes

      def tracer
        @tracer || ::OpenTelemetry.tracer_provider.tracer("little_ghost", LittleGhost::VERSION)
      end

      def start_span(name, attributes)
        kind = name.to_sym
        if kind == :run
          entrypoint_kind = attributes[:entrypoint_kind]&.to_sym
          kind = entrypoint_kind if %i[workflow swarm graph assembly].include?(entrypoint_kind)
        end
        parent = @mutex.synchronize { @entries[attributes[:parent_operation_id]] }
        if kind == :agent && parent&.fetch(:kind) == :run &&
            parent[:agent_id].to_s == attributes[:agent_id].to_s
          alias_primary_agent(attributes, parent)
          return
        end

        parent_context = if parent
          ::OpenTelemetry::Trace.context_with_span(parent.fetch(:span))
        elsif attributes[:trace_context].is_a?(Hash)
          trace_context_propagator.extract(attributes[:trace_context])
        end
        options = {
          kind: span_kind(kind),
          attributes: span_attributes(attributes, kind:).merge(
            "gen_ai.operation.name" => OPERATIONS.fetch(kind, kind.to_s)
          )
        }
        links = trace_links(attributes[:trace_links])
        options[:links] = links unless links.empty?
        span = if parent_context
          tracer.start_span(span_name(kind, attributes), with_parent: parent_context, **options)
        elsif links.empty?
          tracer.start_span(span_name(kind, attributes), **options)
        else
          tracer.start_root_span(span_name(kind, attributes), **options)
        end
        @mutex.synchronize do
          @entries[attributes.fetch(:operation_id)] = {
            span:,
            kind:,
            alias: false,
            agent_id: attributes[:agent_id]
          }
        end
      end

      def alias_primary_agent(attributes, parent)
        span = parent.fetch(:span)
        span_attributes(attributes, kind: :agent).each do |key, value|
          span.set_attribute(key, value)
        end
        @mutex.synchronize do
          @entries[attributes.fetch(:operation_id)] = {
            span:,
            kind: :agent,
            alias: true,
            agent_id: attributes[:agent_id]
          }
        end
      end

      def finish_span(name, attributes)
        entry = @mutex.synchronize { @entries.delete(attributes[:operation_id]) }
        return add_event(:orphan_finish, attributes.merge(instrumentation_name: name)) unless entry

        span = entry.fetch(:span)
        finish_attributes = attributes.except(:diagnostic_input, :diagnostic_tool_definitions)
        span_attributes(finish_attributes, kind: entry.fetch(:kind)).each do |key, value|
          span.set_attribute(key, value)
        end
        return if entry.fetch(:alias)

        record_status(span, attributes, kind: entry.fetch(:kind))
        span.finish
      end

      def record_status(span, attributes, kind:)
        error_type = attributes[:error_type] || attributes[:error_class]
        unless error_type
          span.status = ::OpenTelemetry::Trace::Status.ok
          return
        end

        event_attributes = {"exception.type" => error_type.to_s}
        captured = parse_json(attributes[:diagnostic_exception])
        if captured.is_a?(Hash)
          event_attributes["exception.message"] = attribute_value(:exception_message, captured["message"])
          stacktrace = captured["stacktrace"]
          event_attributes["exception.stacktrace"] = String(stacktrace).slice(0, 64_000) if stacktrace
        end
        description = [error_type, event_attributes["exception.message"]].compact.join(": ")
        span.status = ::OpenTelemetry::Trace::Status.error(description)
        event_name = (kind == :model) ? "gen_ai.client.operation.exception" : "exception"
        span.add_event(event_name, attributes: event_attributes.compact)
      end

      def add_event(name, attributes)
        owner_ids = [attributes[:operation_id], attributes[:parent_operation_id]].compact.uniq
        span = @mutex.synchronize do
          owner_ids.filter_map { |owner_id| @entries.dig(owner_id, :span) }.first
        end
        kind = attributes[:event_kind]&.to_sym
        if span
          span.add_event("little_ghost.#{name}", attributes: span_attributes(attributes, kind:))
        else
          tracer.in_span("little_ghost.#{name}", attributes: span_attributes(attributes, kind:)) {}
        end
      end

      def span_name(kind, attributes)
        return attribute_value(:span_name, attributes[:span_name]) if attributes[:span_name]

        detail = case kind
        when :agent, :run then attributes[:agent_name] || attributes[:agent_id]
        when :workflow then attributes[:workflow_name]
        when :swarm, :graph, :assembly then attributes[:assembly_id]
        when :assembly_step then attributes[:participant]
        when :agent_turn then attributes[:turn]
        when :model then attributes[:model_id]
        when :subagent then attributes[:subagent_id] || attributes[:kind]
        when :tool then attributes[:tool_name]
        end
        detail = attribute_value(:span_name, detail) if detail
        [OPERATIONS.fetch(kind, kind.to_s), detail].compact.join(" ")
      end

      def span_attributes(attributes, kind: nil)
        attributes.each_with_object({}) do |(key, value), result|
          next if internal_attribute?(key)

          if key.to_sym == :model_settings
            add_model_settings(result, value)
            next
          end
          if key.to_sym == :diagnostic_tool_definitions
            definitions = parse_json(value)
            if kind == :tool
              add_tool_metadata(result, definitions)
            else
              add_tool_definitions(result, definitions)
            end
            next
          end
          if key.to_sym == :total_tokens
            next
          end
          next if %i[available_tools duration_ms outcome diagnostic_exception].include?(key.to_sym)

          if %i[diagnostic_input diagnostic_output].include?(key.to_sym)
            add_content_attributes(result, key, attribute_value(key, value), kind:, attributes:)
            next
          end

          name = key.to_s.include?(".") ? key.to_s : ATTRIBUTE_NAMES.fetch(key.to_sym, "little_ghost.#{key}")
          normalized = if key.to_sym == :model_provider
            provider_name(value)
          else
            attribute_value(key, value)
          end
          result[name] = gen_ai_usage_value(key, attributes, normalized)
          if key.to_sym == :stop_reason && value
            result["gen_ai.response.finish_reasons"] = [normalized]
          end
        end
      end

      def internal_attribute?(key)
        %i[event_kind operation_id parent_operation_id trace_context trace_links entrypoint_kind span_name].include?(key.to_sym)
      end

      def add_model_settings(attributes, settings)
        settings.to_h.each do |key, value|
          name = REQUEST_SETTING_ATTRIBUTES[key.to_sym]
          attributes[name] = scalar(value) if name && !scalar(value).nil?
        end
      rescue NoMethodError
        nil
      end

      def add_tool_definitions(attributes, definitions)
        return unless definitions.is_a?(Array)

        attributes["gen_ai.tool.definitions"] = json_attribute(
          definitions.map do |definition|
            values = definition.to_h.transform_keys(&:to_sym)
            {
              type: "function",
              name: values[:name],
              description: values[:description],
              parameters: values[:input_schema] || {}
            }
          end
        )
      end

      def add_tool_metadata(attributes, definitions)
        return unless definitions.is_a?(Array) && definitions.first.is_a?(Hash)

        definition = definitions.first
        attributes["gen_ai.tool.description"] = definition["description"].to_s if definition["description"]
      end

      def add_content_attributes(result, key, value, kind:, attributes:)
        return unless %i[diagnostic_input diagnostic_output].include?(key.to_sym)

        prefix = (key.to_sym == :diagnostic_input) ? "input" : "output"
        if %i[agent interrupt tool].include?(kind) &&
            !(kind == :tool && prefix == "output" && attributes[:error_type])
          result["#{prefix}.value"] = value
          result["#{prefix}.mime_type"] = diagnostic_mime_type(value)
        end
        if kind == :tool
          name = (prefix == "input") ? "gen_ai.tool.call.arguments" : "gen_ai.tool.call.result"
          result[name] = value unless prefix == "output" && attributes[:error_type]
        end
        return unless kind == :model

        semantic_name = (prefix == "input") ? "gen_ai.input.messages" : "gen_ai.output.messages"
        messages = canonical_messages(
          value,
          finish_reason: prefix == "output" && (attributes[:stop_reason] || Array(attributes[:finish_reasons]).first)
        )
        if messages
          result[semantic_name] = messages
          result["#{prefix}.value"] = messages
          result["#{prefix}.mime_type"] = "application/json"
        else
          result["#{prefix}.value"] = value
          result["#{prefix}.mime_type"] = diagnostic_mime_type(value)
        end
      end

      def diagnostic_mime_type(value)
        return "application/json" if value.is_a?(Hash) || value.is_a?(Array)

        JSON.parse(value)
        "application/json"
      rescue JSON::ParserError, TypeError
        "text/plain"
      end

      def canonical_messages(value, finish_reason: nil)
        messages = parse_json(value)
        messages = [messages] if messages.is_a?(Hash)
        return unless messages.is_a?(Array)

        normalized_messages = messages.filter_map do |message|
          next unless message.is_a?(Hash)

          role = message["role"].to_s
          next if role.empty?

          normalized = {
            role:,
            parts: Array(message["content"]).filter_map { |part| canonical_message_part(part) }
          }
          normalized[:finish_reason] = finish_reason.to_s if finish_reason
          normalized
        end
        return if normalized_messages.empty?

        json_attribute(normalized_messages)
      end

      def canonical_message_part(part)
        return {type: "text", content: part.to_s} unless part.is_a?(Hash)

        case part["type"]
        when "text", "reasoning"
          {type: part.fetch("type"), content: part["text"].to_s}
        when "tool_use"
          {
            type: "tool_call",
            id: part["id"].to_s,
            name: part["name"].to_s,
            arguments: part["input"] || {}
          }
        when "tool_result"
          {
            type: "tool_call_response",
            id: part["tool_use_id"].to_s,
            response: part["content"]
          }
        when "image", "document"
          {
            type: "blob",
            mime_type: part["media_type"].to_s,
            name: part["name"],
            size: part["bytes"]
          }.compact
        else
          {type: "text", content: part.to_s}
        end
      end

      def span_kind(kind)
        %i[model session_store].include?(kind) ? :client : :internal
      end

      def gen_ai_usage_value(key, attributes, value)
        if key.to_sym == :input_tokens
          return value.to_i + attributes.fetch(:cache_read_tokens, 0).to_i +
              attributes.fetch(:cache_write_tokens, 0).to_i
        end
        return value.to_i + attributes.fetch(:reasoning_tokens, 0).to_i if key.to_sym == :output_tokens

        value
      end

      def trace_links(carriers)
        Array(carriers).filter_map do |carrier|
          next unless carrier.is_a?(Hash)

          context = trace_context_propagator.extract(carrier)
          span_context = ::OpenTelemetry::Trace.current_span(context).context
          ::OpenTelemetry::Trace::Link.new(span_context) if span_context.valid?
        rescue
          nil
        end
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
        when Hash then json_attribute(value)
        else value.to_s.slice(0, MAX_ATTRIBUTE_LENGTH)
        end
      end

      def json_attribute(value)
        JSON.generate(value)
      rescue JSON::GeneratorError, TypeError
        JSON.generate("[UNSERIALIZABLE]")
      end

      def parse_json(value)
        JSON.parse(value) if value.is_a?(String)
      rescue JSON::ParserError
        nil
      end

      def provider_name(value)
        {
          "bedrock" => "aws.bedrock",
          "open_router" => "openrouter"
        }.fetch(value.to_s, value.to_s)
      end

      def trace_context_propagator
        @trace_context_propagator ||=
          ::OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
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
