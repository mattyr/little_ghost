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
      validate_native_schema!(resolved, schema) if schema
      handle = Instrumentation.start(:generation, model_provider: resolved.target.provider, model_id: resolved.model_id, model_role: resolved.role, structured: !schema.nil?)
      usage = Usage.new
      conversation = messages.map { |message| Message.coerce(message) }
      response = complete(resolved, messages: conversation, settings:, schema:, cancellation_token:, deadline:)
      usage += response.usage
      output, errors = schema ? parse_structured(response.message.text, schema) : [response.message.text, []]
      conversation << (schema ? redact_structured_message(response.message, schema) : response.message)
      if schema && !errors.empty?
        repair = Message.new(role: :user, content: "Return only JSON matching the configured output schema. You have one repair attempt. The previous structured result was invalid.")
        conversation << repair
        response = complete(resolved, messages: conversation, settings:, schema:, cancellation_token:, deadline:)
        usage += response.usage
        output, errors = parse_structured(response.message.text, schema)
        conversation << redact_structured_message(response.message, schema)
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

    def complete(model, messages:, settings:, schema:, cancellation_token:, deadline:)
      request = ModelRequest.new(
        messages:, settings:, output_schema: schema,
        required_capabilities: schema ? [:native_structured_output] : [],
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
        strategy: :provider
      ).except(:strategy).freeze
    end

    def validate_native_schema!(model, schema)
      capabilities = model.capabilities
      return if !capabilities.known? || capabilities.native_structured_output?

      raise ConfigurationError, "#{model.target.provider}/#{model.model_id} does not support provider-native structured output"
    end

    def parse_structured(text, schema)
      raise StructuredResultError.new("Structured result exceeds the maximum serialized size", schema_name: schema.fetch(:name)) if text.bytesize > MAX_STRUCTURED_RESULT_BYTES
      value = JSON.parse(text)
      validate_complexity!(value, schema.fetch(:name))
      errors = Tool::SchemaValidator.new(schema.fetch(:schema)).validate(value)
      [value, errors]
    rescue JSON::ParserError
      [nil, ["Structured result is not valid JSON"]]
    rescue StructuredResultError => error
      [nil, [error.message]]
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

    def usage_attributes(usage)
      usage.to_h.except(:total_tokens)
    end
  end
end
