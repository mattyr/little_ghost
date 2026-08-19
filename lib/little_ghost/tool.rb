# frozen_string_literal: true

require "json"

module LittleGhost
  # Give an agent a validated way to call application code. Every tool declares a
  # model-visible name, description, and input shape before implementing its
  # operation.
  #
  #   class TicketStatusTool < LittleGhost::Tool
  #     tool_name "ticket_status"
  #     description "Look up a support ticket's status."
  #     input_schema type: "object", properties: {
  #       ticket_id: {type: "string"}
  #     }, required: ["ticket_id"], additionalProperties: false
  #
  #     def call(input)
  #       {ticket_id: input.fetch("ticket_id"), status: "waiting_on_customer"}
  #     end
  #   end
  #
  #   class CustomerSupportAgent < LittleGhost::Agent
  #     tools TicketStatusTool
  #   end
  #
  #   run = CustomerSupportAgent.ask("What is happening with ticket SUP-481?")
  #   run.response
  #
  # Use application context for authorization, never model-selected input:
  #
  #   class OrderStatusTool < LittleGhost::Tool
  #     description "Look up an order for the current account."
  #     input_schema type: "object", properties: {
  #       order_number: {type: "string"}
  #     }, required: ["order_number"], additionalProperties: false
  #
  #     def call(input)
  #       Orders.status_for(
  #         actor_id: run.invocation.actor_id,
  #         account_id: run.invocation.context.fetch("account_id"),
  #         order_number: input.fetch("order_number")
  #       )
  #     end
  #   end
  #
  #   class OrderSupportAgent < LittleGhost::Agent
  #     tools OrderStatusTool
  #   end
  #
  #   OrderSupportAgent.ask(
  #     "Where is order 481?",
  #     actor_id: authenticated_user.id,
  #     context: {account_id: authenticated_user.account_id}
  #   )
  #
  # Each value comes from a different part of the run:
  #
  # [<tt>input</tt>]
  #   Arguments selected by the model. The schema checks their shape, not their
  #   permission to perform an operation.
  # [<tt>run.invocation.context</tt>]
  #   Current request values supplied by the application. Use these for
  #   authorization after the application authenticates the caller.
  # [<tt>context.state</tt>]
  #   Mutable working state for the run. It may include values restored from a
  #   Session, so check saved values again before trusting them.
  # [Tool::Binding]
  #   Run-scoped objects such as the Agent, Run, Runtime, workspace, and sandbox.
  #   The Binding supplies #run; it does not contain model arguments.
  #
  # The class DSL produces the specification sent to models. During an Agent
  # run, the tool registry creates and binds one Tool instance. Tests and custom
  # integrations may call +execute+ directly; it validates the arguments, calls
  # +call+, and returns an ExecutionResult. Tool.define offers the same contract
  # for an embedded implementation.
  #
  # Mutable Tool instance state belongs to one Agent run. Registries close tool
  # instances that implement +close+; <tt>exclusive true</tt> prevents that tool
  # from overlapping other exclusive tools in the same run.
  #
  # Validation and application ToolError failures become error results. A
  # ToolError message is visible to the model and must be safe to disclose;
  # unexpected exception messages are replaced with their class name.
  # Cancellation, deadlines, and cleanup errors propagate instead of becoming
  # ordinary tool output. The configured sandbox, not Tool itself, enforces
  # filesystem and process isolation.
  #
  # See the {Tools guide}[rdoc-ref:docs/guides/tools.md] for the complete path
  # from model-selected input to application context, sandbox
  # delegation, concurrency, and code mode.
  class Tool
    # Supply run-scoped collaborators when tools are instantiated outside an agent.
    # A binding can be copied with selected collaborators replaced.
    #
    # Tool instances expose the bound agent, run, runtime, model, workspace, and
    # sandbox through matching accessors. A Binding does not carry model Tool
    # arguments or application state; the current RunContext carries that state.
    # ToolRegistry and Agent normally create bindings on behalf of application
    # code.
    class Binding
      # Agent, run, runtime, model, workspace, and sandbox available to a tool.
      attr_reader :agent, :run, :runtime, :model, :workspace, :sandbox

      # Creates a binding from any available run-scoped collaborators.
      def initialize(agent: nil, run: nil, runtime: nil, model: nil, workspace: nil, sandbox: nil)
        @agent = agent
        @run = run
        @runtime = runtime
        @model = model
        @workspace = workspace
        @sandbox = sandbox
      end

      # Copies the binding, replacing only the supplied collaborators.
      def with(agent: self.agent, run: self.run, runtime: self.runtime, model: self.model,
        workspace: self.workspace, sandbox: self.sandbox)
        self.class.new(agent:, run:, runtime:, model:, workspace:, sandbox:)
      end

      # Instantiates each supplied tool class against this binding.
      def build(*tool_classes)
        tool_classes.flatten.map { |tool_class| tool_class.new(binding: self) }
      end
    end

    # Report the caller-safe outcome of one tool execution.
    # The result retains model-facing content, status, and the original exception
    # for application-side inspection.
    ExecutionResult = Data.define(:content, :status, :error, :companion_content) do # :nodoc:
      def initialize(content:, status:, error: nil, companion_content: [])
        companions = Array(companion_content)
        unless companions.all? do |block|
          block.is_a?(Content::Text) || block.is_a?(Content::Image) || block.is_a?(Content::Document)
        end
          raise ArgumentError, "companion content must contain only text, images, or documents"
        end

        super(content:, status:, error:, companion_content: companions.dup.freeze)
      end

      def success?
        status == :success
      end

      def error?
        status == :error
      end
    end

    # Reports the caller-safe outcome of one tool execution. It keeps
    # model-facing content and status beside the original exception retained for
    # application-side inspection. Companion content lets a tool place trusted
    # text, images, or documents in the next model request without putting those
    # blocks inside a provider-specific tool-result shape.
    class ExecutionResult < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(content:, status:, error: nil, companion_content: []) -> ExecutionResult
      #
      # Collects the model-facing and application-facing parts of one result.

      ##
      # :attr_reader: content
      # The normalized, caller-safe text returned to the model.

      ##
      # :attr_reader: status
      # Either +:success+ or +:error+.

      ##
      # :attr_reader: error
      # The original exception for application-side inspection, when present.

      ##
      # :attr_reader: companion_content
      # Frozen Text, Image, and Document blocks appended as a transient user
      # message after the ordinary tool result.

      ##
      # :method: success?
      # Indicates that +status+ is +:success+.

      ##
      # :method: error?
      # Indicates that +status+ is +:error+.
    end

    extend Support::ClassAttributes

    class_attribute :tool_name_value
    class_attribute :description_value
    class_attribute :input_schema_value
    class_attribute :exclusive_value, default: false

    class << self
      # :call-seq:
      #   tool_name()       -> String
      #   tool_name(value)  -> value
      #
      # The model-visible tool name.
      #
      # Named classes derive a snake-cased default; passing +value+ replaces it.
      def tool_name(*values)
        return configured_name if values.empty?

        self.tool_name_value = String(values.fetch(0)).freeze
      end

      # :call-seq:
      #   description()       -> String
      #   description(value)  -> value
      #
      # The model-visible description used to decide when the tool applies.
      def description(*values)
        return description_value if values.empty?

        self.description_value = String(values.fetch(0)).freeze
      end

      # :call-seq:
      #   input_schema()        -> Hash
      #   input_schema(schema)  -> schema
      #
      # The frozen JSON Schema subset used to validate model input.
      #
      # Setting a non-Hash schema raises ArgumentError. Keys are normalized to
      # strings and the entire value is deeply frozen.
      def input_schema(*values)
        return input_schema_value || {}.freeze if values.empty?

        value = values.fetch(0)
        raise ArgumentError, "input_schema must be a hash" unless value.is_a?(Hash)

        self.input_schema_value = deep_freeze(value)
      end

      # :call-seq:
      #   exclusive()       -> true or false
      #   exclusive(value)  -> value
      #
      # Whether calls acquire the run-wide exclusive tool lock.
      def exclusive(*values)
        return !!exclusive_value if values.empty?

        self.exclusive_value = !!values.fetch(0)
      end

      # Creates an anonymous Tool subclass backed by +implementation+.
      # The block receives +input+ and may also accept the +context:+ keyword.
      #
      #   tool = LittleGhost::Tool.define(
      #     name: "echo", description: "Echo text.",
      #     input_schema: {type: "object"}
      #   ) { |input| input.fetch("text") }
      def define(name:, description:, input_schema: {}, &implementation)
        raise ArgumentError, "A tool implementation block is required" unless implementation

        Class.new(self) do
          tool_name(name)
          description(description)
          input_schema(input_schema)

          define_method(:call) do |input|
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

      # The frozen model-facing name, description, and input schema.
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

    # RunContext supplied to the current #execute call, or nil outside execution.
    attr_reader :context

    # Model-visible name declared by the tool class.
    def tool_name = self.class.tool_name
    # Model-visible description declared by the tool class.
    def description = self.class.description
    # Normalized JSON input schema declared by the tool class.
    def input_schema = self.class.input_schema
    # Frozen provider-facing tool specification.
    def specification = self.class.specification
    # Indicates whether calls use the run-wide exclusive-tool lock.
    def exclusive? = self.class.exclusive

    # Creates a tool with the run-scoped collaborators in +binding+.
    def initialize(binding: Binding.new)
      @binding = binding
      @state = {}
    end

    # Bound agent, when the tool belongs to an agent run.
    def agent = binding.agent
    # Bound run, when available.
    def run = binding.run
    # Bound runtime, when available.
    def runtime = binding.runtime
    # Bound model, when available.
    def model = binding.model
    # Bound workspace, when available.
    def workspace = binding.workspace
    # Bound sandbox, when available.
    def sandbox = binding.sandbox

    # Validates +input+ and invokes the tool, returning an ExecutionResult.
    #
    # Cancellation, deadline, and cleanup exceptions remain control-flow
    # exceptions. ToolError and unexpected failures become sanitized error
    # results; unexpected exception messages are not exposed to the model.
    def execute(input, context: RunContext.new)
      context ||= RunContext.new
      errors = SchemaValidator.new(self.class.input_schema).validate(input)
      unless errors.empty?
        message = "Invalid tool input: #{errors.join("; ")}"
        return failure(message, error: ToolError.new(message))
      end

      value = bound_for(context).call(input)
      return normalize_execution_result(value) if value.is_a?(ExecutionResult)

      success(sanitize(value))
    rescue CancelledError, DeadlineExceededError, CleanupError
      raise
    rescue ToolError => error
      failure(error.message, error:)
    rescue => error
      failure("Tool failed (#{error.class})", error:)
    end

    # Implements the model-requested operation.
    #
    # Subclasses must override this method. The current RunContext is available
    # through +context+ while the call executes.
    def call(_input)
      raise AbstractMethodError, "#{self.class} must implement #call"
    end

    # Releases resources owned by this tool. Subclasses may override it.
    def close
    end

    protected

    attr_reader :binding
    attr_writer :context

    private

    def bound_for(context)
      dup.tap { |tool| tool.context = context }
    end

    attr_reader :state

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

    def normalize_execution_result(result)
      ExecutionResult.new(
        content: sanitize(result.content).freeze,
        status: result.status,
        error: result.error,
        companion_content: result.companion_content
      )
    end

    class SchemaValidator # :nodoc:
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
