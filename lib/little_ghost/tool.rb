# frozen_string_literal: true

require "json"

module LittleGhost
  class Tool
    ExecutionResult = Data.define(:content, :status, :error) do
      def initialize(content:, status:, error: nil)
        super
      end

      def success?
        status == :success
      end

      def error?
        status == :error
      end
    end

    extend Support::ClassAttributes

    class_attribute :tool_name_value
    class_attribute :description_value
    class_attribute :input_schema_value
    class_attribute :exclusive_value, default: false

    class << self
      def tool_name(*values)
        return configured_name if values.empty?

        self.tool_name_value = String(values.fetch(0)).freeze
      end

      def description(*values)
        return description_value if values.empty?

        self.description_value = String(values.fetch(0)).freeze
      end

      def input_schema(*values)
        return input_schema_value || {}.freeze if values.empty?

        value = values.fetch(0)
        raise ArgumentError, "input_schema must be a hash" unless value.is_a?(Hash)

        self.input_schema_value = deep_freeze(value)
      end

      def exclusive(*values)
        return !!exclusive_value if values.empty?

        self.exclusive_value = !!values.fetch(0)
      end

      def define(name:, description:, input_schema: {}, &implementation)
        raise ArgumentError, "A tool implementation block is required" unless implementation

        Class.new(self) do
          tool_name(name)
          description(description)
          input_schema(input_schema)

          define_method(:call) do |input, context:|
            accepts_context = implementation.parameters.any? do |kind, parameter|
              kind == :keyrest || (%i[key keyreq].include?(kind) && parameter == :context)
            end
            if accepts_context
              implementation.call(input, context: context)
            else
              implementation.call(input)
            end
          end
        end
      end

      def specification
        {
          name: tool_name,
          description: description,
          input_schema: input_schema
        }.freeze
      end

      private

      def configured_name
        return tool_name_value if tool_name_value

        class_name = Module.instance_method(:name).bind_call(self)
        return if class_name.nil?

        class_name.split("::").last
          .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
          .downcase
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[key.to_s.freeze] = deep_freeze(child)
          end.freeze
        when Array
          value.map { |child| deep_freeze(child) }.freeze
        else
          value.freeze
        end
      end
    end

    attr_reader :run

    def tool_name = self.class.tool_name
    def description = self.class.description
    def input_schema = self.class.input_schema
    def specification = self.class.specification
    def exclusive? = self.class.exclusive

    def initialize(run: nil)
      @run = run
    end

    def execute(input, context: nil)
      errors = SchemaValidator.new(self.class.input_schema).validate(input)
      unless errors.empty?
        message = "Invalid tool input: #{errors.join("; ")}"
        return failure(message, error: ToolError.new(message))
      end

      success(sanitize(call(input, context: context)))
    rescue CancelledError, DeadlineExceededError, CleanupError
      raise
    rescue ToolError => error
      failure(error.message, error:)
    rescue => error
      failure("Tool failed (#{error.class})", error:)
    end

    def call(_input, context:)
      raise NotImplementedError, "#{self.class} must implement #call"
    end

    private

    def sanitize(value)
      case value
      when String then value
      when nil then ""
      when Hash, Array then JSON.generate(value)
      else value.to_s
      end
    rescue JSON::GeneratorError
      raise ToolError, "Tool returned content that cannot be serialized"
    end

    def success(content)
      ExecutionResult.new(content: content.freeze, status: :success)
    end

    def failure(content, error:)
      ExecutionResult.new(content: content.freeze, status: :error, error:)
    end

    class SchemaValidator
      def initialize(schema)
        @schema = schema
      end

      def validate(value)
        errors = []
        validate_value(@schema, value, "$", errors)
        errors
      end

      private

      def validate_value(schema, value, path, errors)
        return unless schema.is_a?(Hash)

        validate_type(schema["type"], value, path, errors)
        validate_enum(schema["enum"], value, path, errors)
        validate_number(schema, value, path, errors) if value.is_a?(Numeric)
        validate_string(schema, value, path, errors) if value.is_a?(String)
        validate_object(schema, value, path, errors) if value.is_a?(Hash)
        validate_array(schema, value, path, errors) if value.is_a?(Array)
      end

      def validate_type(type, value, path, errors)
        return if type.nil? || Array(type).any? { |candidate| type_matches?(candidate, value) }

        errors << "#{path} must be #{Array(type).join(" or ")}"
      end

      def validate_enum(enum, value, path, errors)
        return if enum.nil? || enum.include?(value)

        errors << "#{path} must be one of #{enum.map(&:inspect).join(", ")}"
      end

      def validate_number(schema, value, path, errors)
        minimum = schema["minimum"]
        maximum = schema["maximum"]
        errors << "#{path} must be at least #{minimum}" if minimum && value < minimum
        errors << "#{path} must be at most #{maximum}" if maximum && value > maximum
      end

      def validate_object(schema, value, path, errors)
        properties = schema.fetch("properties", {})
        required = schema.fetch("required", [])

        required.each do |key|
          errors << "#{path}.#{key} is required" unless key?(value, key)
        end

        value.each do |key, child|
          property_schema = properties[key.to_s]
          if property_schema
            validate_value(property_schema, child, "#{path}.#{key}", errors)
          elsif schema["additionalProperties"] == false
            errors << "#{path}.#{key} is not allowed"
          elsif schema["additionalProperties"].is_a?(Hash)
            validate_value(schema["additionalProperties"], child, "#{path}.#{key}", errors)
          end
        end
      end

      def validate_string(schema, value, path, errors)
        minimum = schema["minLength"]
        maximum = schema["maxLength"]
        pattern = schema["pattern"]
        errors << "#{path} must have at least #{minimum} characters" if minimum && value.length < minimum
        errors << "#{path} must have at most #{maximum} characters" if maximum && value.length > maximum
        errors << "#{path} has an invalid format" if pattern && !Regexp.new(pattern).match?(value)
      rescue RegexpError
        errors << "#{path} has an invalid schema pattern"
      end

      def validate_array(schema, value, path, errors)
        minimum = schema["minItems"]
        maximum = schema["maxItems"]
        errors << "#{path} must contain at least #{minimum} items" if minimum && value.length < minimum
        errors << "#{path} must contain at most #{maximum} items" if maximum && value.length > maximum
        return unless schema["items"].is_a?(Hash)

        value.each_with_index do |child, index|
          validate_value(schema["items"], child, "#{path}[#{index}]", errors)
        end
      end

      def type_matches?(type, value)
        case type.to_s
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer)
        when "number" then value.is_a?(Numeric)
        when "boolean" then value == true || value == false
        when "null" then value.nil?
        else false
        end
      end

      def key?(value, key)
        value.key?(key) || value.key?(key.to_sym)
      end
    end
  end
end
