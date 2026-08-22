# frozen_string_literal: true

require "json"

module LittleGhost
  # Executes bounded model operations without creating an Agent or Run.
  class ModelOperations # :nodoc:
    MAX_STRUCTURED_RESULT_BYTES = 1_000_000
    MAX_STRUCTURED_RESULT_DEPTH = 64
    MAX_STRUCTURED_RESULT_NODES = 100_000

    def initialize(model_resolver:)
      @model_resolver = model_resolver
    end

    def generate(model:, messages:, result_schema: nil, settings: {}, cancellation_token: Support::CancellationToken.new, deadline: nil)
      resolved = @model_resolver.resolve(model)
      schema = normalize_schema(result_schema)
      strategy = StructuredOutput.resolve(schema, model: resolved, ordinary_tools: []) if schema
      handle = Instrumentation.start(:generation, model_provider: resolved.target.provider, model_id: resolved.model_id, model_role: resolved.role, structured: !schema.nil?)
      usage = Usage.new
      conversation = messages.map { |message| Message.coerce(message) }
      response = complete(resolved, messages: conversation, settings:, schema:, strategy:, repair: false, cancellation_token:, deadline:)
      usage += response.usage
      output, errors = schema ? parse_structured_response(response.message, schema, strategy) : [response.message.text, []]
      conversation << (schema ? redact_structured_response(response.message, schema, strategy) : response.message)
      if schema && !errors.empty?
        conversation << structured_repair_message(response.message, strategy)
        response = complete(resolved, messages: conversation, settings:, schema:, strategy:, repair: true, cancellation_token:, deadline:)
        usage += response.usage
        output, errors = parse_structured_response(response.message, schema, strategy)
        conversation << redact_structured_response(response.message, schema, strategy)
      end
      unless errors.empty?
        raise StructuredResultError.new(
          "The model did not return a valid structured result after its repair attempt",
          schema_name: schema.fetch(:name), validation_errors: errors
        )
      end
      handle.finish(outcome: :success, **usage_attributes(usage))
      structured_result = StructuredResult.new(schema_name: schema.fetch(:name), value: output) if schema
      final_message = schema ? conversation.last : response.message
      RunResult.new(
        message: final_message,
        stop_reason: schema ? :structured_result : response.stop_reason,
        usage:,
        messages: conversation.freeze,
        state: DataMap.new,
        structured_result:,
        steps: []
      )
    rescue => error
      handle&.finish(outcome: :error, error_type: error.class.name) if handle&.active?
      raise
    end

    def embed(model:, inputs:, settings: {}, limits: {}, cancellation_token: Support::CancellationToken.new, deadline: nil)
      request = Embeddings::Request.new(inputs:, settings:, limits:, cancellation_token:, deadline:)
      resolved = @model_resolver.resolve(model)
      handle = Instrumentation.start(:embedding, model_provider: resolved.target.provider, model_id: resolved.model_id, model_role: resolved.role, input_count: request.inputs.length)
      response = resolved.embed(request)
      metadata = response.metadata.merge(provider: resolved.target.provider, model: resolved.model_id, model_role: resolved.role, input_count: request.inputs.length).compact
      result = Embeddings::Response.new(vectors: response.vectors, usage: response.usage, metadata:)
      handle.finish(outcome: :success, dimensions: result.dimensions, **usage_attributes(result.usage))
      result
    rescue => error
      handle&.finish(outcome: :error, error_type: error.class.name) if handle&.active?
      raise
    end

    private

    def complete(model, messages:, settings:, schema:, strategy:, repair:, cancellation_token:, deadline:)
      request = ModelRequest.new(
        messages:, settings:,
        tools: strategy ? strategy.tools([]) : [],
        output_schema: strategy&.output_schema,
        tool_choice: strategy&.tool_choice(repair:),
        required_capabilities: strategy ? strategy.required_capabilities : [],
        cancellation_token:, deadline:
      )
      response = nil
      model.stream(request) do |event|
        response = event.data[:response] if event.type == :message_stop
      end
      response || raise(ProtocolError, "Provider stream ended without a response")
    end

    def normalize_schema(value)
      return unless value
      raise ArgumentError, "result_schema must be a mapping" unless value.respond_to?(:to_h)

      schema = value.to_h.transform_keys(&:to_sym)
      name = schema.fetch(:name).to_s
      json_schema = schema.fetch(:schema)
      Class.new(Agent).result_schema(
        json_schema,
        name:,
        description: schema[:description],
        strategy: :auto
      ).except(:strategy).freeze
    end

    def parse_structured_response(message, schema, strategy)
      return parse_structured(message.text, schema) if strategy.provider?

      tool_uses = message.content.grep(Content::ToolUse)
      result_tool_uses = tool_uses.select { |tool_use| tool_use.name == strategy.schema_name }
      return [nil, ["The structured result tool was not called"]] if result_tool_uses.empty?
      return [nil, ["The model called the structured result tool more than once"]] if result_tool_uses.length > 1
      return [nil, ["The structured result tool must be the only tool call in its response"]] if tool_uses.length > 1

      validate_structured_value(result_tool_uses.first.input, schema)
    end

    def parse_structured(text, schema)
      raise StructuredResultError.new("Structured result exceeds the maximum serialized size", schema_name: schema.fetch(:name)) if text.bytesize > MAX_STRUCTURED_RESULT_BYTES
      value = JSON.parse(text)
      validate_structured_value(value, schema)
    rescue JSON::ParserError
      [nil, ["Structured result is not valid JSON"]]
    rescue StructuredResultError => error
      [nil, [error.message]]
    end

    def validate_structured_value(value, schema)
      validate_complexity!(value, schema.fetch(:name))
      errors = Tool::SchemaValidator.new(schema.fetch(:schema)).validate(value)
      [value, errors]
    rescue StructuredResultError => error
      [nil, [error.message]]
    end

    def structured_repair_message(message, strategy)
      tool_uses = message.content.grep(Content::ToolUse)
      if strategy.tool? && !tool_uses.empty?
        return Message.new(
          role: :tool,
          content: tool_uses.map do |tool_use|
            Content::ToolResult.new(
              tool_use_id: tool_use.id,
              content: "The structured result was invalid. Submit it again using the required schema.",
              status: :error
            )
          end
        )
      end

      requirement = strategy.tool? ? "Call #{strategy.schema_name} exactly once as your only tool call." : "Return only JSON matching the configured output schema."
      Message.new(role: :user, content: "#{requirement} You have one repair attempt. The previous structured result was invalid.")
    end

    def validate_complexity!(value, schema_name)
      nodes = 0
      stack = [[value, 1]]
      until stack.empty?
        child, depth = stack.pop
        nodes += 1
        raise StructuredResultError.new("Structured result exceeds the maximum nesting depth", schema_name:) if depth > MAX_STRUCTURED_RESULT_DEPTH
        raise StructuredResultError.new("Structured result exceeds the maximum complexity", schema_name:) if nodes > MAX_STRUCTURED_RESULT_NODES
        child.each { |key, nested| stack << [key, depth + 1] << [nested, depth + 1] } if child.is_a?(Hash)
        child.each { |nested| stack << [nested, depth + 1] } if child.is_a?(Array)
      end
    end

    def redact_structured_message(message, schema)
      Message.new(
        role: message.role,
        content: "[Structured result #{schema.fetch(:name)} redacted]",
        metadata: message.metadata
      )
    end

    def redact_structured_response(message, schema, strategy)
      tool_uses = message.content.grep(Content::ToolUse)
      return redact_structured_message(message, schema) unless strategy.tool? && !tool_uses.empty?

      Message.new(
        role: message.role,
        content: tool_uses.map do |tool_use|
          Content::ToolUse.new(id: tool_use.id, name: tool_use.name, input: {})
        end,
        metadata: message.metadata
      )
    end

    def usage_attributes(usage)
      usage.to_h.except(:total_tokens)
    end
  end
end
