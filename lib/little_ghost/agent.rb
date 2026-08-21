# frozen_string_literal: true

require "securerandom"
require_relative "assembly"
require_relative "support/output_truncation"
require_relative "tool_execution"

module LittleGhost
  # Defines one reusable model-driven behavior with prompts, tools, and limits.
  # Each Agent subclass describes one application role with an inheritable Ruby
  # DSL. It can answer, stream, call tools, and delegate work.
  #
  # Start with one role and add capabilities as its work grows:
  #
  #   class CustomerSupportAgent < LittleGhost::Agent
  #     description "Handles support requests"
  #     model "openrouter:openai/gpt-5.6-luna"
  #     system_prompt "Answer customer questions clearly."
  #   end
  #
  #   run = CustomerSupportAgent.ask("Why is transfer 481 pending?")
  #   run.completed? # => true
  #   run.response
  #   # One possible response: Transfer 481 is waiting for the receiving bank.
  #
  # An Agent is the smallest Assembly: it owns one model loop while inheriting
  # the same +ask+ and +stream_ask+ entrypoints as coordinated assemblies.
  # Add tools for application operations and subagents for model-directed
  # delegation.
  #
  # Call a named Agent with
  # ask[rdoc-ref:LittleGhost::Assembly.ask] when you need the final Run, or
  # the streaming entrypoint[rdoc-ref:LittleGhost::Assembly.stream_ask] when you
  # want events as the answer arrives.
  #
  # Most applications call a named Agent class. LittleGhost automatically
  # reuses the active Configuration's shared Runtime while building a fresh
  # top-level Run for every call. Passing +runtime:+ is an advanced option for
  # an explicitly isolated setup.
  #
  # Agent declarations are inherited. Define a short prompt inline, or place a
  # growing prompt in <tt>app/prompts/customer_support/system.erb</tt> for
  # +CustomerSupportAgent+. The {Prompts as Views guide}[rdoc-ref:docs/guides/prompt_views.md]
  # explains conventional lookup, locals, and partials. Optional features such
  # as skills, context management, loop detection, and delegation stay inactive
  # until their DSL is used.
  #
  # Models may return text or locally validated structured data. LittleGhost
  # hides unexpected Tool exception messages from the model. See
  # Run[rdoc-ref:LittleGhost::Run] for outcomes, cancellation, and cleanup, and
  # Assembly[rdoc-ref:LittleGhost::Assembly] for the advanced run-scoped form.
  class Agent < Assembly
    DEFAULT_SYSTEM_PROMPT = "You are a helpful agent." # :nodoc:
    DEFAULT_MAX_TOOL_RESULT_TOKENS = 10_000 # :nodoc:
    MAX_STRUCTURED_RESULT_BYTES = 1_000_000 # :nodoc:
    MAX_STRUCTURED_RESULT_DEPTH = 64 # :nodoc:
    MAX_STRUCTURED_RESULT_NODES = 100_000 # :nodoc:
    RESULT_SCHEMA_KEYWORDS = %w[
      $schema title description type enum minimum maximum minLength maxLength
      properties required additionalProperties minItems maxItems items
    ].freeze # :nodoc:
    CALLBACKS = %i[
      after_initialize
      before_invocation after_invocation
      before_model after_model after_model_error
      before_tool after_tool
    ].freeze # :nodoc:
    ExecutedTool = Data.define(:result, :execution_result) do # :nodoc:
      def status = result.status
      def content = result.content
      def value = execution_result.value
      def artifacts = execution_result.artifacts
      def presentation_content = execution_result.presentation_content
    end

    extend Support::ClassAttributes

    class_attribute :model_value
    class_attribute :limits_value, default: {}
    class_attribute :result_schema_value
    class_attribute :capture_diagnostics_value, default: true
    class_attribute :system_template_value
    class_attribute :system_prompt_value
    class_attribute :system_prompt_builder_value
    class_attribute :tool_declarations_value, default: []
    class_attribute :code_mode_configuration_value
    class_attribute :prompt_local_values, default: {}
    class_attribute :callback_values, default: Support::Callbacks.new(*CALLBACKS)

    class << self
      # :call-seq:
      #   agent_id() -> String
      #   agent_id(value) -> String
      #
      # The stable identifier used in telemetry, delegation, and default tool names.
      # Named subclasses derive it from their underscored class name without an
      # +Agent+ suffix; passing +value+ replaces that default.
      def agent_id(*values)
        return assembly_id if values.empty?

        assembly_id(values.fetch(0))
      end

      # The underscored, namespace-aware path used for conventional prompt lookup.
      def logical_path
        parts = name.to_s.split("::")
        parts[-1] = parts.last.sub(/Agent\z/, "") if parts.any?
        parts.reject(&:empty?).map { |part| underscore(part) }.join("/")
      end

      # :call-seq:
      #   model() -> String, Symbol, Hash, Proc, nil
      #   model(role_or_target) -> String, Symbol
      #   model(provider:, model:, **settings) -> Hash
      #   model { |invocation| ... } -> Proc
      #
      # Selects this agent's model by logical role, canonical
      # <tt>provider:model-id</tt> target, or an inline mapping with +provider+,
      # +model+, and trusted model settings. The provider names a configured
      # connection, not necessarily its adapter.
      #
      # Pass a block to choose any supported form from each Invocation at run
      # time. Inline mappings use flat settings, for example:
      #
      #   model(provider: "openai", model: "gpt-5.6-luna", reasoning_effort: "high")
      def model(*values, &block)
        return model_value if values.empty? && !block
        if block && !values.empty?
          raise ArgumentError, "model accepts either one selection or a block"
        end
        if values.length > 1
          raise ArgumentError, "model accepts one selection"
        end

        self.model_value = block || copy_model_selection(values.fetch(0))
      end

      def model_selection(invocation) # :nodoc:
        value = model_value
        value.is_a?(Proc) ? value.call(invocation) : value
      end

      # :call-seq:
      #   limits() -> Hash
      #   limits(**values) -> Hash
      #
      # Inherited execution limits for model turns, tool calls, and tool output.
      #
      # Keyword arguments merge into the current limits and the zero-argument
      # form returns them.
      def limits(**values)
        return limits_value if values.empty?

        self.limits_value = limits.merge(values.transform_keys(&:to_sym))
      end

      # :call-seq:
      #   result_schema() -> Hash, nil
      #   result_schema(schema, name: nil, description: nil, strategy: :auto) -> Hash
      #   result_schema(name: nil, description: nil, strategy: :auto, **schema) -> Hash
      #
      # Declares a strict JSON-object result contract. Every object must set
      # <tt>additionalProperties: false</tt> and require each property. Automatic
      # strategy selection prefers provider-native structured output and falls
      # back to a terminal tool when supported.
      #
      # During execution, a missing or invalid result receives one repair attempt
      # before LittleGhost::StructuredResultError is raised inside the owning Run.
      # A top-level +ask+ records it on a failed Run. Invalid schemas and strategies
      # raise LittleGhost::ConfigurationError before execution begins.
      def result_schema(schema = nil, name: nil, description: nil, strategy: :auto, **schema_keywords)
        return result_schema_value if schema.nil? && schema_keywords.empty? && name.nil? && description.nil? && strategy == :auto

        if schema.nil?
          schema = schema_keywords
        elsif !schema_keywords.empty?
          raise ArgumentError, "Provide result_schema as a hash or keyword schema, not both"
        end

        raise ArgumentError, "result_schema must be a hash" unless schema.is_a?(Hash)

        normalized_schema = Class.new(Tool).tap { |tool| tool.input_schema(schema) }.input_schema
        validate_result_schema_keywords!(normalized_schema)
        unless normalized_schema["type"] == "object"
          raise ConfigurationError, "result_schema must describe a top-level object"
        end

        schema_name = (name || "#{agent_id}_result").to_s
        unless schema_name.match?(/\A[a-zA-Z0-9_-]{1,64}\z/)
          raise ConfigurationError, "result_schema name must contain 1-64 letters, numbers, underscores, or hyphens"
        end
        strategy = strategy.to_sym
        unless StructuredOutput::STRATEGIES.include?(strategy)
          raise ConfigurationError, "result_schema strategy must be auto, provider, or tool"
        end

        self.result_schema_value = {
          schema: normalized_schema,
          name: schema_name,
          description: description&.to_s,
          strategy:
        }
      end

      # :call-seq:
      #   capture_diagnostics() -> true or false
      #   capture_diagnostics(value) -> true or false
      #
      # Whether agent-layer diagnostics may include model and tool content.
      #
      # Capture defaults to +true+, and only a literal +true+ enables it. This
      # setting does not disable run-level input and output capture from an
      # enabled process-wide Support::ContentCapture policy. For sensitive work,
      # also install Support::ContentCapture.disabled or an appropriate scrubber
      # through Instrumentation.capture_content.
      def capture_diagnostics(*values)
        return capture_diagnostics_value if values.empty?

        self.capture_diagnostics_value = values.fetch(0) == true
      end

      # :call-seq:
      #   system_template() -> String, nil
      #   system_template(path) -> String
      #
      # The explicit system prompt template path, when conventional lookup is not used.
      def system_template(*values)
        return system_template_value if values.empty?

        self.system_template_value = values.fetch(0).to_s
      end

      # :call-seq:
      #   system_prompt() -> String, Proc, nil
      #   system_prompt(value) -> String
      #   system_prompt { |locals| ... } -> Proc
      #
      # The inline system prompt or prompt-building block.
      #
      # Setting an inline prompt clears +system_template+ so one source remains
      # authoritative.
      def system_prompt(*values, &block)
        return system_prompt_builder_value || system_prompt_value if values.empty? && !block

        self.system_template_value = nil
        if block
          self.system_prompt_value = nil
          self.system_prompt_builder_value = block
        else
          self.system_prompt_value = values.fetch(0).to_s
          self.system_prompt_builder_value = nil
        end
      end

      # Adds tool or provider classes to the agent.
      #
      # Every declaration must be a class. Pass Tool classes directly, or pass
      # provider classes that supply tools dynamically through
      # <tt>tools(binding)</tt>. Multiple declarations are cumulative.
      def tools(*values)
        invalid = values.flatten.compact.find { |value| !value.is_a?(Class) }
        if invalid
          raise ConfigurationError, "Class-level tools must be classes"
        end

        declarations = tool_declarations_value + values
        self.tool_declarations_value = declarations
        tool_declarations
      end

      def tool_declarations = tool_declarations_value # :nodoc:

      # Enables code mode for this agent. +except+ names the application Tools
      # that remain model-facing; every other application Tool moves into the
      # engine catalog and is called through the parent-process Broker.
      # Framework-owned subagent controls remain model-facing automatically.
      def code_mode(engine: nil, except: nil, **options)
        unknown = options.keys - %i[sandbox limits]
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

        declaration = options.merge(engine:, except:).compact
        self.code_mode_configuration_value = declaration.freeze
      end

      def code_mode_configuration = code_mode_configuration_value # :nodoc:

      # Adds a named value or resolver to every prompt rendered for the agent.
      def prompt_local(name, *values, &resolver)
        raise ArgumentError, "Provide a prompt local value or block" if values.empty? && !resolver
        raise ArgumentError, "Provide a prompt local value or block, not both" unless values.empty? || !resolver

        self.prompt_local_values = prompt_local_values.merge(name.to_sym => resolver || values.fetch(0))
      end

      def prompt_local_resolvers = prompt_local_values # :nodoc:

      def callbacks = callback_values # :nodoc:

      CALLBACKS.each do |name|
        define_method(name) do |callable = nil, prepend: false, &block|
          callbacks = callback_values.dup
          callbacks.on(name, callable, prepend:, &block)
          self.callback_values = callbacks
          self
        end
      end

      ##
      # Prepares per-agent state after a run-scoped instance is initialized.
      #
      # :singleton-method: after_initialize
      # :call-seq:
      #   after_initialize(callable = nil, prepend: false) { |agent| ... } -> self

      ##
      # Runs before one invocation begins.
      #
      # The payload is <tt>{messages: Array<Message>}</tt>. A replacement must
      # contain +:messages+. Cancellation stops the invocation. A callback may
      # also accept <tt>context:</tt> to receive the current RunContext.
      #
      # :singleton-method: before_invocation
      # :call-seq:
      #   before_invocation(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Observes or transforms the terminal invocation payload.
      #
      # The payload is <tt>{result: RunResult}</tt>. A replacement must contain
      # +:result+. Cancellation stops result delivery. A callback may accept
      # <tt>context:</tt>.
      #
      # :singleton-method: after_invocation
      # :call-seq:
      #   after_invocation(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Runs before a model request is sent.
      #
      # The payload contains +:request+ (ModelRequest), zero-based +:turn+, and
      # +:parent_operation_id+. A replacement must contain +:request+.
      # Cancellation stops the invocation. A callback may accept
      # <tt>context:</tt>.
      #
      # :singleton-method: before_model
      # :call-seq:
      #   before_model(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Observes or transforms a successful model response.
      #
      # The payload contains +:request+, +:response+ (ModelResponse), and
      # zero-based +:turn+. A replacement must contain +:response+.
      # Cancellation stops the invocation. A callback may accept
      # <tt>context:</tt>.
      #
      # :singleton-method: after_model
      # :call-seq:
      #   after_model(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Handles a model error before it leaves the agent loop.
      #
      # The payload contains +:request+, +:error+, zero-based +:turn+, and
      # +:parent_operation_id+. Replacing +:request+ with a ModelRequest retries
      # the model call, up to the framework recovery limit. Cancellation stops
      # the invocation. A callback may accept <tt>context:</tt>.
      #
      # :singleton-method: after_model_error
      # :call-seq:
      #   after_model_error(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Runs after validation but before a tool call starts.
      #
      # The payload contains +:tool_use+, the bound +:tool+, +:operation_id+,
      # and +:parent_operation_id+. Cancellation returns a model-visible Tool
      # error, so its reason must be safe to disclose. Replacements are not
      # consumed. A callback may accept <tt>context:</tt>.
      #
      # :singleton-method: before_tool
      # :call-seq:
      #   before_tool(callable = nil, prepend: false) { |payload| ... } -> self

      ##
      # Observes or transforms a completed tool result.
      #
      # The payload contains the before-tool fields plus the normalized
      # +:result+. A replacement must contain +:result+.
      # Cancellation is not consumed. A callback may accept <tt>context:</tt>.
      #
      # :singleton-method: after_tool
      # :call-seq:
      #   after_tool(callable = nil, prepend: false) { |payload| ... } -> self

      private

      def copy_model_selection(value)
        case value
        when String
          value.dup.freeze
        when Symbol
          value
        when Hash
          value.to_h { |key, child| [key, copy_model_selection_value(child)] }.freeze
        else
          raise ConfigurationError, "model must be a role, provider:model target, or configuration mapping"
        end
      end

      def copy_model_selection_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key, copy_model_selection_value(child)] }.freeze
        when Array
          value.map { |child| copy_model_selection_value(child) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      def validate_result_schema_keywords!(schema, path = "$")
        unsupported = schema.keys - RESULT_SCHEMA_KEYWORDS
        unless unsupported.empty?
          raise ConfigurationError,
            "result_schema contains unsupported keywords at #{path}: #{unsupported.sort.join(", ")}"
        end

        validate_result_schema_values!(schema, path)
        schema.fetch("properties", {}).each do |name, child|
          validate_result_schema_keywords!(child, "#{path}.properties.#{name}")
        end
        items = schema["items"]
        validate_result_schema_keywords!(items, "#{path}.items") if items
        additional = schema["additionalProperties"]
        if additional.is_a?(Hash)
          validate_result_schema_keywords!(additional, "#{path}.additionalProperties")
        end
      end

      def validate_result_schema_values!(schema, path)
        type = schema["type"]
        types = Array(type)
        supported_types = %w[object array string integer number boolean null]
        if type && (types.empty? || !types.all? { |value| supported_types.include?(value) })
          raise ConfigurationError, "result_schema has an invalid type at #{path}"
        end
        if schema.key?("properties") &&
            (!schema["properties"].is_a?(Hash) || !schema["properties"].values.all? { |value| value.is_a?(Hash) })
          raise ConfigurationError, "result_schema properties must contain object schemas at #{path}"
        end
        if schema.key?("required") &&
            (!schema["required"].is_a?(Array) || !schema["required"].all? { |value| value.is_a?(String) })
          raise ConfigurationError, "result_schema required must be an array of strings at #{path}"
        end
        if type == "object" || Array(type).include?("object") || schema.key?("properties")
          properties = schema.fetch("properties", {})
          unless schema["additionalProperties"] == false
            raise ConfigurationError, "result_schema object must set additionalProperties to false at #{path}"
          end
          unless schema["required"]&.sort == properties.keys.sort
            raise ConfigurationError, "result_schema object must require every property at #{path}"
          end
        end
        if schema.key?("items") && !schema["items"].is_a?(Hash)
          raise ConfigurationError, "result_schema items must be an object schema at #{path}"
        end
        additional = schema["additionalProperties"]
        if schema.key?("additionalProperties") && additional != true && additional != false && !additional.is_a?(Hash)
          raise ConfigurationError, "result_schema additionalProperties must be boolean or an object schema at #{path}"
        end
        if schema.key?("enum") &&
            (!schema["enum"].is_a?(Array) || !schema["enum"].all? { |value| json_schema_value?(value) })
          raise ConfigurationError, "result_schema enum must contain only JSON values at #{path}"
        end
        %w[minimum maximum].each do |keyword|
          if schema.key?(keyword) &&
              (!schema[keyword].is_a?(Numeric) ||
                (schema[keyword].respond_to?(:finite?) && !schema[keyword].finite?))
            raise ConfigurationError, "result_schema #{keyword} must be finite and numeric at #{path}"
          end
        end
        %w[minLength maxLength minItems maxItems].each do |keyword|
          if schema.key?(keyword) && (!schema[keyword].is_a?(Integer) || schema[keyword].negative?)
            raise ConfigurationError, "result_schema #{keyword} must be a non-negative integer at #{path}"
          end
        end
        %w[$schema title description].each do |keyword|
          if schema.key?(keyword) && !schema[keyword].is_a?(String)
            raise ConfigurationError, "result_schema #{keyword} must be a string at #{path}"
          end
        end
      end

      def json_schema_value?(value)
        case value
        when String, Integer, true, false, nil
          true
        when Numeric
          !value.respond_to?(:finite?) || value.finite?
        when Array
          value.all? { |child| json_schema_value?(child) }
        when Hash
          value.all? { |key, child| key.is_a?(String) && json_schema_value?(child) }
        else
          false
        end
      end

      def underscore(value)
        value.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end
    end

    # The resolved model used by this run-scoped Agent.
    attr_reader :model
    # Tools created and bound for this Agent's owning Run.
    attr_reader :tool_registry
    # The owning Run, or +nil+ for a standalone entrypoint.
    attr_reader :run
    # Shared delegation tracker, when subagents are enabled.
    attr_reader :delegation_activity
    # This Agent's location in the bounded subagent tree.
    attr_reader :agent_path
    # Run-scoped workspace available to Tools and extensions.
    attr_reader :workspace
    # Run-scoped sandbox used for filesystem and process operations.
    attr_reader :sandbox
    # Maximum Tool calls allowed during one invocation.
    attr_reader :max_tool_calls

    # Creates either a standalone entrypoint or a run-scoped agent.
    # :call-seq:
    #   new(runtime: nil) -> Agent
    #   new(model:, runtime:, tools:, run:, ...) -> Agent
    #
    # The first form is the application-facing entrypoint. It may be reused for
    # independent concurrent calls and creates a fresh Run for each one. The
    # second form is run-scoped; Runtime builders supply its dependencies and it
    # must not outlive or be shared outside its owning Run.
    def initialize(
      model: nil,
      runtime: nil,
      tools: [],
      template_resolver: nil,
      template_paths: [],
      run: nil,
      executor: nil,
      delegation_activity: nil,
      agent_path: Subagents::AgentPath::ROOT,
      max_turns: 100,
      max_tool_calls: 1_000,
      max_tool_result_tokens: DEFAULT_MAX_TOOL_RESULT_TOKENS,
      model_settings: {},
      workspace: nil,
      sandbox: nil
    )
      standalone = model.nil? && run.nil?
      super(run:, runtime:, workspace:, sandbox:, standalone:)
      if standalone
        @owns_resources = true
        @closed = false
        @close_mutex = Mutex.new
        @interjections_mutex = Mutex.new
        @active_interjections = []
        return
      end

      @model = model
      @runtime = runtime || run&.runtime
      @run = run
      @workspace = workspace || run&.workspace
      @sandbox = sandbox || run&.sandbox
      if @runtime.is_a?(Runtime) && !@workspace
        @workspace = @runtime.build_workspace
        @sandbox ||= @runtime.build_sandbox(workspace: @workspace)
      end
      @owns_resources = run.nil? && (@workspace || @sandbox)
      binding = Tool::Binding.new(agent: self, run:, runtime: @runtime, model:, workspace: @workspace, sandbox: @sandbox)
      @tool_registry = ToolRegistry.new(tools, binding:)
      self.class.tool_declarations.each do |declaration|
        @tool_registry.register(declaration, replace: true)
      end
      initialize_code_mode
      @structured_output_strategy = StructuredOutput.resolve(
        self.class.result_schema,
        model:,
        ordinary_tools: @tool_registry.specifications
      )
      @model_settings = model_settings.to_h.freeze
      @template_resolver = template_resolver || default_template_resolver(template_paths)
      @executor = executor || Support::Executor.new(runner: task_runner)
      @delegation_activity = delegation_activity
      @agent_path = Subagents::AgentPath.validate!(agent_path)
      @max_turns = Integer(max_turns)
      @max_tool_calls = Integer(max_tool_calls)
      @max_tool_result_tokens = Integer(max_tool_result_tokens)
      @closed = false
      @close_mutex = Mutex.new
      @exclusive_tools_mutex = Mutex.new
      @interjections_mutex = Mutex.new
      @active_interjections = []
      @assembly_transitions_mutex = Mutex.new
      @assembly_transitions = {}
      @assembly_tool_batch_sizes = {}
      @assembly_transition = nil
      raise ArgumentError, "max_turns must be at least 1" if @max_turns < 1
      raise ArgumentError, "max_tool_calls must be at least 1" if @max_tool_calls < 1
      raise ArgumentError, "max_tool_result_tokens must be at least 1" if @max_tool_result_tokens < 1
      @artifact_lifecycle = @runtime&.then do |resolved_runtime|
        resolved_runtime.runtime_hooks.find { |hook| hook.is_a?(Runtime::Hooks::Artifacts) }
      end
      apply_cancellation_decision!(run_callbacks(:after_initialize, self))
    rescue
      @tool_registry&.close
      @code_mode_runtime&.close
      raise
    end

    # Runtime used to build this agent's model, tools, workspace, and sandbox.
    attr_reader :runtime

    def entrypoint_name = self.class.agent_id # :nodoc:

    def dispatch_tools(tool_uses, context:, events:, parent_operation_id:, parent_trace_context: nil) # :nodoc:
      counted = tool_uses.count { |tool_use| !code_mode_control_tool?(tool_use) }
      context.record_tool_calls!(counted, maximum: @max_tool_calls) if counted.positive?
      execute_tools(
        tool_uses,
        context,
        events,
        parent_operation_id:,
        parent_trace_context:
      )
    end

    def code_mode_runtime # :nodoc:
      @code_mode_runtime || raise(ConfigurationError, "code mode is not enabled for this agent")
    end

    def request_assembly_transition(value, context:) # :nodoc:
      @assembly_transitions_mutex.synchronize do
        unless @assembly_tool_batch_sizes[context] == 1
          raise ToolError, "An assembly transition must be the only tool call in a model response"
        end
        if @assembly_transitions.key?(context)
          raise ProtocolError, "Multiple assembly transitions were requested in one agent turn"
        end

        @assembly_transitions[context] = value
      end
      value
    end

    attr_reader :assembly_transition # :nodoc:

    # Adds an interjection and returns the model's immediate result details.
    #
    # Use +target_operation_id+ when an agent has multiple active invocations.
    # Messages may contain only text, image, or document content. The returned
    # result value exposes +text+, +tool_calls?+, +interjection_ids+, and
    # +batch_key+; tool calls may continue after this result. Depend on these
    # methods rather than the result's concrete class.
    def interject(
      message,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      target_operation_id: nil,
      interjection_id: nil,
      batch_key: nil,
      metadata: {}
    )
      message = Message.new(role: :user, content: message) if message.is_a?(String)
      raise ArgumentError, "interject message must be a String or LittleGhost::Message" unless message.is_a?(Message)
      safe_content = message.content.all? do |content|
        content.is_a?(Content::Text) ||
          content.is_a?(Content::Image) ||
          content.is_a?(Content::Document)
      end
      unless safe_content
        raise ArgumentError, "interject message content must contain only text, images, or documents"
      end

      interjections = @interjections_mutex.synchronize do
        active = if target_operation_id
          @active_interjections.select { |candidate| candidate.target_operation_id == target_operation_id }
        else
          @active_interjections
        end
        if active.empty?
          raise AgentInterjectionError, "Agent is not currently running"
        end
        if active.length > 1
          raise AgentInterjectionError, "Agent has multiple active invocations; the interjection target is ambiguous"
        end

        active.first
      end
      options = {batch_key:, metadata:}
      options[:id] = interjection_id unless interjection_id.nil?
      ticket = interjections.enqueue(message, **options)
      instrument(
        :agent_interjection_queued,
        parent_operation_id: interjections.operation_id,
        interjection_id: ticket.id,
        event_kind: :interjection,
        diagnostic: {input: diagnostic_message(message)}
      )
      begin
        response = ticket.value(cancellation_token:, deadline:)
        interjections.release(ticket)
        response
      rescue => error
        interjections.release(ticket, withdraw: true)
        instrument(
          :agent_interjection_failed,
          parent_operation_id: interjections.operation_id,
          interjection_id: ticket.id,
          event_kind: :interjection,
          error_type: error.class.name,
          diagnostic: {exception: diagnostic_exception(error)}
        )
        raise
      end
    end

    # Streams one invocation as StreamEvent objects.
    #
    # Agents built inside a run accept history, JSON-like context, cancellation,
    # deadlines, settings, and trusted invocation template paths. An Agent
    # instance may be streamed only by its owning Run. Every template path must
    # be an application-created TrustedPath;
    # the wrapper records a trust decision and must never contain unchecked
    # request or model input.
    def stream(
      input = nil,
      history: nil,
      context: nil,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      settings: nil,
      template_locals: nil,
      template_paths: nil,
      parent_operation_id: nil,
      checkpoint: nil,
      conversation_id: nil,
      interjection_metadata: nil,
      interjection_ids: [],
      interject_ready: nil
    )
      if standalone?
        raise ArgumentError, "input is required" if input.nil?

        return build_run(entrypoint_payload(input, {
          history:,
          context:,
          settings:,
          template_paths:,
          deadline_at: deadline,
          cancellation_token:
        }.compact)).each
      end

      raise ArgumentError, "input is required" if input.nil?

      history ||= []
      context ||= {}
      settings ||= {}
      template_locals ||= {}
      template_paths ||= []
      invocation_paths = Array(template_paths).map do |path|
        unless path.is_a?(LittleGhost::TrustedPath)
          raise ArgumentError, "invocation template paths must be LittleGhost::TrustedPath values"
        end
        path
      end
      settings = @model_settings.merge(settings)
      Enumerator.new do |events|
        interjections = AgentInterjections.new
        run_context = RunContext.new(
          state: context,
          cancellation_token: cancellation_token,
          deadline: deadline,
          metadata: {agent_id: self.class.agent_id},
          checkpoint:,
          conversation_id:,
          interjection_metadata:,
          interjection_ids:
        )
        begin
          with_invocation(run_context) do
            execute(
              input,
              history: history,
              context: run_context,
              settings: settings,
              template_locals: template_locals,
              template_paths: invocation_paths,
              events: events,
              parent_operation_id:,
              interjections:,
              interject_ready:
            )
          end
        rescue => error
          interjections.close(error)
          raise
        ensure
          @code_mode_runtime&.close(context: run_context)
          interjections.close(AgentInterjectionError.new("Agent finished before the interjection was delivered"))
          unregister_interjections(interjections)
        end
      end
    end

    # Materializes and freezes the prompt locals declared on the agent class.
    def prompt_locals
      self.class.prompt_local_resolvers.to_h do |name, resolver|
        value = if resolver.respond_to?(:call)
          resolver.parameters.empty? ? instance_exec(&resolver) : resolver.call(self)
        else
          resolver
        end
        [name, value]
      end.freeze
    end

    # The Tool registry available during this Agent run.
    def tools = tool_registry

    # Closes owned tools, interjections, sandbox, and workspace resources.
    # The operation is idempotent and re-raises the first cleanup failure.
    def close
      resources, interjections = @close_mutex.synchronize do
        return if @closed

        @closed = true
        [
          [@code_mode_runtime, tool_registry, (@sandbox if @owns_resources), (@workspace if @owns_resources)],
          @interjections_mutex.synchronize { @active_interjections.dup }
        ]
      end
      first_error = nil
      interjections.each do |active|
        active.close(AgentInterjectionError.new("Agent was closed"))
      end
      resources.each do |resource|
        resource.close if resource.respond_to?(:close)
      rescue => error
        first_error ||= error
      end
      raise first_error if first_error
    end

    protected

    # :doc:
    # Yields around one invocation. Subclasses may override this hook to install
    # invocation-scoped state and must yield exactly once.
    def with_invocation(_context)
      yield
    end

    # :doc:
    # Returns the tools exposed to the model for +turn+. Subclasses may override
    # this hook to filter the already-authorized tool list.
    def model_tools(tools, context:, turn:)
      return tools unless @code_mode_runtime

      exceptions = Array(@code_mode_declaration[:except]).map(&:to_s)
      tools.select do |specification|
        name = specification.fetch(:name, specification["name"]).to_s
        tool = tool_registry.fetch(name) if tool_registry.names.include?(name)
        exceptions.include?(name) || %w[exec wait stop].include?(name) ||
          tool.is_a?(Subagents::ControlTool) || !tool
      end
    end

    # :doc:
    # Yields around one tool execution. Subclasses may override this hook for
    # execution-scoped behavior and must yield exactly once.
    def with_tool_execution(_execution)
      yield
    end

    private

    def entrypoint_payload(input, options)
      return options if input.nil?
      return input.merge(options) if input.is_a?(Hash)

      {message: input, **options}
    end

    def register_interjections(interjections)
      @close_mutex.synchronize do
        raise InvocationError, "Agent is closed" if @closed

        @interjections_mutex.synchronize { @active_interjections << interjections }
      end
    end

    def unregister_interjections(interjections)
      @interjections_mutex.synchronize { @active_interjections.delete(interjections) }
    end

    def interjection_message(interjection)
      source = interjection.message
      Message.new(
        role: :user,
        content: [
          Content::Text.new(text: <<~MESSAGE.strip),
            Agent interjection:

            Respond briefly in ordinary text before any tool calls, then continue the current task unless this
            interjection asks you to finish.
          MESSAGE
          *source.content
        ],
        metadata: source.metadata.merge(interjection.metadata).merge(
          little_ghost_interjection_id: interjection.id,
          little_ghost_interjection_batch_key: interjection.batch_key,
          little_ghost_interjection_metadata: interjection.metadata
        )
      )
    end

    def request_with_interjection(request, interjection)
      ModelRequest.new(
        messages: [
          *request.messages,
          *interjection.tickets.reject { |ticket| request_contains_interjection?(request, ticket) }
            .map { |ticket| interjection_message(ticket) }
        ],
        tools: request.tools,
        settings: request.settings,
        output_schema: nil,
        tool_choice: nil,
        required_capabilities: request.tools.empty? ? [] : [:tools],
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
    end

    def request_contains_interjection?(request, interjection)
      request.messages.any? do |message|
        (message.metadata[:little_ghost_interjection_id] ||
          message.metadata["little_ghost_interjection_id"]) == interjection.id
      end
    end

    def consume_assembly_transition(context)
      @assembly_transitions_mutex.synchronize { @assembly_transitions.delete(context) }
    end

    def with_assembly_tool_batch(context, size)
      @assembly_transitions_mutex.synchronize { @assembly_tool_batch_sizes[context] = size }
      yield
    ensure
      @assembly_transitions_mutex.synchronize { @assembly_tool_batch_sizes.delete(context) }
    end

    def execute(
      input,
      history:,
      context:,
      settings:,
      template_locals:,
      template_paths:,
      events:,
      parent_operation_id:,
      interjections:,
      interject_ready:
    )
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
      events = agent_stream_events(
        events,
        input:,
        operation_id:,
        parent_operation_id:
      )
      context.bind_agent_operation_id(operation_id)
      @assembly_transitions_mutex.synchronize { @assembly_transition = nil }
      interjections.bind(operation_id, target_operation_id: parent_operation_id)
      register_interjections(interjections)
      interject_ready&.call
      agent_handle = start_instrumentation(
        :agent,
        parent: parent_operation_id || active_instrumentation_parent,
        operation_id:,
        available_tools: tool_registry.names,
        diagnostic: {input: diagnostic_input(input)}
      )
      context.check!
      messages = history.map { |message| Message.coerce(message) }
      prompt = rendered_system_prompt(template_locals, template_paths)
      messages.unshift(Message.new(role: :system, content: prompt)) unless prompt.to_s.empty?
      messages << (input.is_a?(Message) ? input : Message.new(role: :user, content: input))
      structured_result_repair_due = false

      decision = run_callbacks(:before_invocation, {messages: messages}, context: context)
      apply_cancellation_decision!(decision)
      messages = replacement_value(decision, :messages, messages)
      context.checkpoint(messages)
      emit(events, :invocation_start, agent_id: self.class.agent_id)

      @max_turns.times do |turn|
        turn_operation_id = SecureRandom.uuid
        turn_handle = start_instrumentation(
          :agent_turn,
          operation_id: turn_operation_id,
          turn: turn + 1
        )
        begin
          context.check!
          response, interjected = invoke_model(
            messages,
            context,
            settings,
            turn,
            events,
            parent_operation_id: turn_operation_id,
            structured_result_repair_due:,
            interjections:
          )
          messages.reject! { |message| artifact_presentation_message?(message) }
          messages << response.message
          tool_uses = response.message.content.grep(Content::ToolUse)
          result_tool_uses = structured_result_tool_uses(tool_uses)

          unless result_tool_uses.empty?
            validation_error = capture_structured_result_tool(
              tool_uses,
              result_tool_uses,
              context
            )
            unless validation_error
              messages[-1] = redact_structured_result_message(response.message)
              unless interjections.finish
                context.checkpoint(messages)
                finish_instrumentation(
                  turn_handle,
                  operation_id: turn_operation_id,
                  outcome: :interjected,
                  turn: turn + 1
                )
                next
              end
              return complete_structured_result(
                response,
                messages,
                context,
                events,
                agent_handle:,
                turn_handle:,
                turn: turn + 1,
                started_at:,
                repaired: structured_result_repair_due
              )
            end

            if structured_result_repair_due
              raise_structured_result_error!(
                "The model did not return a valid structured result after its repair turn",
                context,
                operation_id:,
                started_at:,
                validation_errors: [validation_error]
              )
            end

            structured_result_repair_due = true
            messages[-1] = redact_structured_result_tool_message(response.message)
            messages << Message.new(
              role: :tool,
              content: structured_result_tool_errors(tool_uses)
            )
            context.checkpoint(messages)
            instrument_structured_result_repair(
              operation_id,
              started_at,
              context,
              validation_status: :invalid
            )
            finish_instrumentation(
              turn_handle,
              operation_id: turn_operation_id,
              outcome: :repair,
              turn: turn + 1
            )
            next
          end

          if tool_uses.empty?
            if %i[max_tokens limit_output_tokens limit_total_tokens limit_turns].include?(response.stop_reason)
              raise OutputLimitError, "The model stopped before completing its response"
            end

            if interjected || !@structured_output_strategy
              unless interjections.finish
                context.checkpoint(messages)
                finish_instrumentation(
                  turn_handle,
                  operation_id: turn_operation_id,
                  outcome: :interjected,
                  turn: turn + 1
                )
                next
              end
            end

            if @structured_output_strategy && !interjected
              validation_error = if @structured_output_strategy.provider?
                capture_structured_result(response.message.text, context)
              else
                "The structured result tool was not called"
              end
              unless validation_error
                messages[-1] = redact_structured_result_message(response.message)
                unless interjections.finish
                  context.checkpoint(messages)
                  finish_instrumentation(
                    turn_handle,
                    operation_id: turn_operation_id,
                    outcome: :interjected,
                    turn: turn + 1
                  )
                  next
                end
                return complete_structured_result(
                  response,
                  messages,
                  context,
                  events,
                  agent_handle:,
                  turn_handle:,
                  turn: turn + 1,
                  started_at:,
                  repaired: structured_result_repair_due
                )
              end

              if structured_result_repair_due
                raise_structured_result_error!(
                  "The model did not return a valid structured result after its repair turn",
                  context,
                  operation_id:,
                  started_at:,
                  validation_errors: [validation_error]
                )
              end

              structured_result_repair_due = true
              messages[-1] = redact_structured_result_message(response.message)
              messages << structured_result_repair_message
              context.checkpoint(messages)
              instrument_structured_result_repair(
                operation_id,
                started_at,
                context,
                validation_status: :missing
              )
              finish_instrumentation(
                turn_handle,
                operation_id: turn_operation_id,
                outcome: :repair,
                turn: turn + 1
              )
              next
            end

            context.checkpoint(messages)

            result = RunResult.new(
              message: response.message,
              stop_reason: response.stop_reason,
              usage: context.usage,
              messages: messages.freeze,
              state: context.state
            )
            decision = run_callbacks(:after_invocation, {result: result}, context: context)
            apply_cancellation_decision!(decision)
            result = replacement_value(decision, :result, result)
            context.checkpoint(result.messages)
            finish_instrumentation(
              turn_handle,
              operation_id: turn_operation_id,
              outcome: :completed,
              turn: turn + 1
            )
            metadata = model.details.to_h.merge(model_role: model.role)
            finish_instrumentation(
              agent_handle,
              outcome: :completed,
              duration_ms: duration_ms(started_at),
              stop_reason: result.stop_reason,
              operation_id:,
              diagnostic: {output: diagnostic_message(result.message)},
              **usage_attributes(result.usage)
            )
            emit(events, :invocation_stop, result: result, metadata:)
            return result
          end

          if @structured_output_strategy && structured_result_repair_due
            raise_structured_result_error!(
              "The model did not return a structured result after its repair turn",
              context,
              operation_id:,
              started_at:,
              validation_errors: ["The structured result was not returned"]
            )
          end

          executed_tools = with_assembly_tool_batch(context, tool_uses.length) do
            dispatch_tools(
              tool_uses,
              context:,
              events:,
              parent_operation_id: turn_operation_id
            )
          end
          messages << Message.new(
            role: :tool,
            content: executed_tools.map(&:result),
            metadata: artifact_message_metadata(executed_tools)
          )
          executed_tools.each do |executed_tool|
            next if executed_tool.presentation_content.empty?

            messages << Message.new(
              role: :user,
              content: executed_tool.presentation_content,
              metadata: {transient: true, little_ghost_artifact_presentation: true}
            )
          end
          context.checkpoint(messages)
          transition = consume_assembly_transition(context)
          if transition
            result = RunResult.new(
              message: response.message,
              stop_reason: :assembly_transition,
              usage: context.usage,
              messages: messages.freeze,
              state: context.state
            )
            decision = run_callbacks(:after_invocation, {result:}, context:)
            apply_cancellation_decision!(decision)
            result = replacement_value(decision, :result, result)
            @assembly_transition = transition
            context.checkpoint(result.messages)
            finish_instrumentation(
              turn_handle,
              operation_id: turn_operation_id,
              outcome: :completed,
              turn: turn + 1
            )
            metadata = model.details.to_h.merge(model_role: model.role)
            finish_instrumentation(
              agent_handle,
              outcome: :completed,
              duration_ms: duration_ms(started_at),
              stop_reason: result.stop_reason,
              operation_id:,
              diagnostic: {output: diagnostic_message(result.message)},
              **usage_attributes(result.usage)
            )
            emit(events, :invocation_stop, result:, metadata:)
            return result
          end
          finish_instrumentation(
            turn_handle,
            operation_id: turn_operation_id,
            outcome: :completed,
            turn: turn + 1
          )
        rescue => error
          finish_instrumentation(
            turn_handle,
            operation_id: turn_operation_id,
            outcome: :error,
            turn: turn + 1,
            error_type: error.class.name,
            diagnostic: {exception: diagnostic_exception(error)}
          )
          raise
        end
      end

      if @structured_output_strategy
        raise_structured_result_error!(
          structured_result_repair_due ?
            "The agent reached its model turn limit before it could repair the structured result" :
            "The agent reached its model turn limit before returning a structured result",
          context,
          operation_id:,
          started_at:,
          validation_errors: [
            structured_result_repair_due ? "repair turn unavailable" : "structured result was not submitted"
          ],
          repair_attempted: structured_result_repair_due
        )
      end
      raise ProtocolError, "The agent reached its maximum model turns"
    rescue => error
      @assembly_transitions_mutex.synchronize do
        @assembly_transitions.delete(context)
        @assembly_tool_batch_sizes.delete(context)
      end
      finish_instrumentation(
        agent_handle,
        operation_id:,
        outcome: :error,
        duration_ms: duration_ms(started_at),
        error_type: error.class.name,
        diagnostic: {exception: diagnostic_exception(error)},
        **usage_attributes(context.usage)
      )
      metadata = model.details.to_h.merge(model_role: model.role)
      emit(events, :invocation_error, error:, usage: context.usage, metadata:)
      raise
    end

    def invoke_model(
      messages,
      context,
      settings,
      turn,
      events,
      parent_operation_id:,
      interjections:,
      structured_result_repair_due: false,
      recovery_attempt: 0,
      interjection: nil
    )
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
      strategy = @structured_output_strategy
      ordinary_tools = tool_registry.specifications
      StructuredOutput.validate_tool_collision!(strategy, ordinary_tools) if strategy
      request = ModelRequest.new(
        messages: messages,
        tools: model_tools(strategy ? strategy.tools(ordinary_tools) : ordinary_tools, context:, turn:),
        settings: settings,
        output_schema: strategy&.output_schema,
        tool_choice: strategy&.tool_choice(repair: structured_result_repair_due),
        required_capabilities: strategy&.required_capabilities || [],
        cancellation_token: context.cancellation_token,
        deadline: context.deadline
      )
      interjection ||= interjections.deliver
      if interjection
        context.activate_interjection(metadata: interjection.metadata, ids: interjection.interjection_ids)
      end
      decision = run_callbacks(
        :before_model,
        {request: request, turn: turn, parent_operation_id:},
        context: context
      )
      apply_cancellation_decision!(decision)
      request = replacement_value(decision, :request, request)
      interjection_delivered = interjection&.tickets&.any? do |ticket|
        !request_contains_interjection?(request, ticket)
      end
      if interjection_delivered
        request = request_with_interjection(request, interjection)
      end
      messages.replace(request.messages)
      context.checkpoint(messages)
      model_handle = start_instrumentation(
        :model,
        operation_id:,
        turn:,
        diagnostic: {
          input: request.messages.map { |message| diagnostic_message(message) },
          tool_definitions: request.tools
        },
        model_settings: request.settings,
        **model_attributes
      )
      if interjection_delivered
        interjection.tickets.each do |ticket|
          instrument(
            :agent_interjection_delivered,
            parent_operation_id: operation_id,
            interjection_id: ticket.id,
            event_kind: :interjection
          )
        end
        emit(
          events,
          :agent_interjection_delivered,
          interjection_ids: interjection.interjection_ids,
          batch_key: interjection.batch_key
        )
      end
      emit(events, :model_start, turn: turn)
      response = nil
      time_to_first_token = nil
      buffered_events = strategy ? [] : nil
      code_mode_control_indexes = {}

      model.stream(request).each do |event|
        context.check!
        time_to_first_token ||= duration_seconds(started_at) if model_output_event?(event)
        if event.type == :model_retry
          response = nil
          instrument(
            :model_retry,
            parent_operation_id: operation_id,
            **event.data.slice(
              :attempt,
              :delay,
              :error_class,
              :error_code,
              :http_status,
              :partial_text
            ),
            **model_attributes
          )
        end
        unless code_mode_control_event?(event, code_mode_control_indexes)
          buffered_events ? buffered_events << event : events << event
        end
        response = event.data[:response] if event.type == :message_stop
      end
      raise ProtocolError, "The model stream ended without a response" unless response

      context.record_usage(response.usage)
      provider_response = response

      decision = run_callbacks(:after_model, {request: request, response: response, turn: turn}, context: context)
      apply_cancellation_decision!(decision)
      response = replacement_value(decision, :response, response)
      interjections.resolve(
        interjection,
        AgentInterjections::Result.new(
          text: response.message.text,
          tool_calls: response.message.content.any? { |content| content.is_a?(Content::ToolUse) },
          interjection_ids: interjection&.interjection_ids || [],
          batch_key: interjection&.batch_key
        )
      )
      interjection&.tickets&.each do |ticket|
        instrument(
          :agent_interjection_responded,
          parent_operation_id: operation_id,
          interjection_id: ticket.id,
          event_kind: :interjection,
          diagnostic: {output: response.message.text}
        )
      end
      if buffered_events
        publish_model_events(
          events,
          buffered_events,
          provider_response,
          response,
          repair: structured_result_repair_due
        )
      end
      redact_response = structured_result_terminal_response?(
        provider_response,
        repair: structured_result_repair_due
      ) || structured_result_terminal_response?(
        response,
        repair: structured_result_repair_due
      )
      diagnostic_response = if redact_response
        redact_structured_result_payload_message(response.message)
      else
        structured_result_diagnostic_message(response.message)
      end
      finish_instrumentation(
        model_handle,
        operation_id:,
        parent_operation_id:,
        turn:,
        outcome: :completed,
        duration_ms: duration_ms(started_at),
        time_to_first_token:,
        stop_reason: response.stop_reason,
        **response_attributes(response),
        diagnostic: {output: diagnostic_message(diagnostic_response)},
        **model_attributes,
        **usage_attributes(response.usage)
      )
      emit(
        events,
        :model_stop,
        turn: turn,
        response: structured_result_stream_response(
          provider_response,
          response,
          repair: structured_result_repair_due
        )
      )
      [response, !interjection.nil?]
    rescue => error
      finish_instrumentation(
        model_handle,
        operation_id:,
        parent_operation_id:,
        turn:,
        outcome: :error,
        duration_ms: duration_ms(started_at),
        time_to_first_token:,
        error_type: error.class.name,
        **provider_error_attributes(error),
        diagnostic: {exception: diagnostic_exception(error)},
        **model_attributes
      )
      raise if error.is_a?(CleanupError)

      if recovery_attempt < 3
        decision = run_callbacks(
          :after_model_error,
          {request:, error:, turn:, parent_operation_id:},
          context:
        )
        apply_cancellation_decision!(decision)
        recovered = replacement_value(decision, :request, nil)
        if recovered
          messages.replace(recovered.messages)
          return invoke_model(
            messages,
            context,
            recovered.settings,
            turn,
            events,
            parent_operation_id:,
            structured_result_repair_due:,
            recovery_attempt: recovery_attempt + 1,
            interjections:,
            interjection:
          )
        end
      end
      raise
    end

    def execute_tools(tool_uses, context, events, parent_operation_id:, parent_trace_context: nil)
      if tool_uses.map(&:id).uniq.length != tool_uses.length
        raise ProtocolError, "The model returned duplicate tool use ids"
      end

      tool_uses.each { |tool_use| emit(events, :tool_start, tool_use: tool_use) unless code_mode_control_tool?(tool_use) }
      presentation_budget = Artifacts::PresentationBudget.new
      pairs = tool_uses.map do |tool_use|
        [tool_use, tool_registry.fetch(tool_use.name)]
      rescue ToolError => error
        [tool_use, error]
      end
      tools = pairs.filter_map { |_tool_use, tool| tool if tool.is_a?(Tool) }
      execution = lambda do |tool_use, tool|
        started_at = monotonic_time
        operation_id = SecureRandom.uuid
        telemetry_tool_name = tool.is_a?(Tool) ? tool.tool_name : "unknown_tool"
        tool_handle = start_instrumentation(
          :tool,
          parent: parent_operation_id || active_instrumentation_parent,
          operation_id:,
          **parent_trace_attributes(parent_trace_context),
          tool_name: telemetry_tool_name,
          tool_type: "function",
          tool_call_id: tool_use.id,
          diagnostic: {
            input: diagnostic_tool_input(tool_use),
            tool_definitions: tool.is_a?(Tool) ? [tool.specification] : []
          }
        )
        if tool.is_a?(ToolError)
          result = build_tool_result(tool_use_id: tool_use.id, content: tool.message, status: :error)
          finish_instrumentation(
            tool_handle,
            operation_id:,
            parent_operation_id:,
            tool_name: telemetry_tool_name,
            outcome: :error,
            duration_ms: duration_ms(started_at),
            error_type: tool.class.name,
            diagnostic: {
              output: diagnostic_tool_result(result, tool:),
              exception: diagnostic_tool_exception(tool, tool:)
            }
          )
          execution_result = Tool::ExecutionResult.new(content: result.content, status: :error, error: tool)
          next ExecutedTool.new(result:, execution_result:)
        end

        context.check!

        callback_payload = {
          tool_use: tool_use,
          tool: tool,
          operation_id: operation_id,
          parent_operation_id: parent_operation_id
        }
        decision = run_callbacks(:before_tool, callback_payload, context: context)
        if decision.cancel?
          rejection = ToolError.new(decision.reason)
          result = build_tool_result(
            tool_use_id: tool_use.id,
            content: decision.reason,
            status: :error
          )
          finish_instrumentation(
            tool_handle,
            operation_id:,
            parent_operation_id:,
            tool_name: telemetry_tool_name,
            outcome: :error,
            duration_ms: duration_ms(started_at),
            error_type: rejection.class.name,
            diagnostic: {
              output: diagnostic_tool_result(result, tool:),
              exception: diagnostic_tool_exception(rejection, tool:)
            }
          )
          execution_result = Tool::ExecutionResult.new(content: result.content, status: :error, error: rejection)
          next ExecutedTool.new(result:, execution_result:)
        end

        execution_context = ToolExecution.new(
          tool_use:,
          tool:,
          context:,
          events:,
          operation_id:,
          parent_operation_id:,
          parent_trace_context:
        )
        invoke = lambda do
          ExecutionState.with(tool_execution: execution_context) do
            with_tool_execution(execution_context) do
              invoke_tool(
                tool_use, tool, context,
                operation_id:, parent_operation_id:
              )
            end
          end
        end
        tool_result = if tool.exclusive? && !code_mode_control_tool?(tool_use)
          synchronize_exclusive_tools(&invoke)
        else
          invoke.call
        end
        after_decision = run_callbacks(
          :after_tool,
          callback_payload.merge(result: tool_result),
          context: context
        )
        tool_result = replacement_value(after_decision, :result, tool_result)
        if @artifact_lifecycle
          tool_result = @artifact_lifecycle.prepare_tool_result(
            tool_result,
            tool_use:,
            run: @run,
            workspace:,
            context:
          )
        end
        tool_result = bound_artifact_presentation(tool_result, presentation_budget)
        result = build_tool_result(
          tool_use_id: tool_use.id,
          content: tool_result.content,
          status: tool_result.status
        )
        tool_error = tool_result.error
        tool_error ||= ToolError.new(result.content) if result.status == :error
        finish_instrumentation(
          tool_handle,
          operation_id:,
          parent_operation_id:,
          tool_name: telemetry_tool_name,
          outcome: result.status,
          duration_ms: duration_ms(started_at),
          error_type: tool_error&.class&.name,
          diagnostic: {
            output: diagnostic_tool_result(result, tool:),
            exception: tool_error && diagnostic_tool_exception(tool_error, tool:)
          }.compact
        )
        ExecutedTool.new(result:, execution_result: tool_result)
      rescue ToolError => error
        result = build_tool_result(tool_use_id: tool_use.id, content: error.message, status: :error)
        finish_instrumentation(
          tool_handle,
          operation_id:,
          parent_operation_id:,
          tool_name: telemetry_tool_name,
          outcome: :error,
          duration_ms: duration_ms(started_at),
          error_type: error.class.name,
          diagnostic: {
            output: diagnostic_tool_result(result, tool:),
            exception: diagnostic_tool_exception(error, tool:)
          }
        )
        execution_result = Tool::ExecutionResult.new(content: result.content, status: :error, error:)
        ExecutedTool.new(result:, execution_result:)
      rescue => error
        finish_instrumentation(
          tool_handle,
          operation_id:,
          parent_operation_id:,
          tool_name: telemetry_tool_name,
          outcome: :error,
          duration_ms: duration_ms(started_at),
          error_type: error.class.name,
          diagnostic: {exception: diagnostic_tool_exception(error, tool:)}
        )
        raise
      end
      if tools.any?(&:exclusive?)
        pairs.map do |tool_use, tool|
          executed_tool = execution.call(tool_use, tool)
          emit(events, :tool_stop, tool_use:, result: executed_tool.result) unless code_mode_control_tool?(tool_use)
          executed_tool
        end
      else
        @executor.map(
          pairs,
          cancellation_token: context.cancellation_token,
          on_result: lambda do |index, executed_tool|
            tool_use = tool_uses.fetch(index)
            emit(events, :tool_stop, tool_use:, result: executed_tool.result) unless code_mode_control_tool?(tool_use)
          end
        ) do |tool_use, tool|
          execution.call(tool_use, tool)
        end
      end
    end

    def bound_artifact_presentation(result, budget)
      accepted = budget.accept(result.presentation_content)
      return result if accepted.equal?(result.presentation_content) || accepted == result.presentation_content

      fallback = result.artifacts.reject do |artifact|
        artifact.metadata[:complete_result] || artifact.metadata["complete_result"]
      end
      references = artifact_references(fallback)
      content = if references.empty?
        result.content
      else
        "#{result.content}\n\nArtifacts:\n#{references.join("\n")}"
      end

      Tool::ExecutionResult.new(
        value: result.value,
        content:,
        status: result.status,
        error: result.error,
        artifacts: result.artifacts,
        presentation_content: accepted
      )
    end

    def artifact_references(artifacts)
      artifacts.filter_map do |artifact|
        next unless artifact.reference.is_a?(String) && artifact.bytes

        details = [artifact.media_type, "#{artifact.bytes} bytes"].compact.join(", ")
        "- #{artifact.reference} (#{details})"
      end
    end

    def artifact_message_metadata(executed_tools)
      artifacts = executed_tools.flat_map(&:artifacts).select do |artifact|
        artifact.reference.is_a?(String) && artifact.bytes
      end
      return {} if artifacts.empty?

      {
        "little_ghost_artifacts" => artifacts.map do |artifact|
          {
            "reference" => artifact.reference,
            "name" => artifact.name,
            "media_type" => artifact.media_type,
            "bytes" => artifact.bytes
          }.compact
        end
      }
    end

    def invoke_tool(tool_use, tool, context, operation_id:, parent_operation_id:)
      tool.execute(tool_use.input, context:)
    end

    def code_mode_control_tool?(tool_use)
      @code_mode_runtime && %w[exec wait stop].include?(tool_use.name)
    end

    def code_mode_control_event?(event, indexes)
      return false unless @code_mode_runtime

      index = event.data[:index]
      case event.type
      when :tool_call_start
        indexes[index] = true if %w[exec wait stop].include?(event.data[:name])
        indexes.key?(index)
      when :tool_call_delta
        indexes.key?(index)
      when :tool_call_stop
        indexes.delete(index)
      else
        false
      end
    end

    def parent_trace_attributes(trace_context)
      return {} unless trace_context.is_a?(Hash) && !trace_context.empty?

      {trace_context:}
    end

    def synchronize_exclusive_tools(&block)
      if run
        run.synchronize_exclusive_tools(&block)
      else
        @exclusive_tools_mutex.synchronize(&block)
      end
    end

    def build_tool_result(tool_use_id:, content:, status:)
      truncated = truncated_tool_result(content)
      Content::ToolResult.new(tool_use_id:, content: truncated.freeze, status:)
    end

    def capture_structured_result(text, context)
      value = JSON.parse(text)
      capture_structured_result_value(value, context)
    rescue JSON::ParserError
      "Structured result is not valid JSON"
    end

    def capture_structured_result_tool(tool_uses, result_tool_uses, context)
      if result_tool_uses.length > 1
        return "The model called the structured result tool more than once"
      end
      if tool_uses.length > 1
        return "The structured result tool must be the only tool call in its response"
      end

      capture_structured_result_value(result_tool_uses.first.input, context)
    end

    def capture_structured_result_value(value, context)
      configuration = self.class.result_schema
      schema_name = configuration.fetch(:name)
      validate_structured_result_limits!(value)
      errors = Tool::SchemaValidator.new(configuration.fetch(:schema)).validate(value)
      return "Structured result does not match its schema: #{errors.join("; ")}" unless errors.empty?

      context.submit_structured_result(
        StructuredResult.new(schema_name:, value:)
      )
      nil
    rescue ToolError => error
      error.message
    end

    def structured_result_tool_uses(tool_uses)
      return [] unless @structured_output_strategy&.tool?

      tool_uses.select { |tool_use| tool_use.name == @structured_output_strategy.schema_name }
    end

    def structured_result_tool_errors(tool_uses)
      tool_uses.map do |tool_use|
        build_tool_result(
          tool_use_id: tool_use.id,
          content: "The structured result was invalid. Submit it again using the required schema.",
          status: :error
        )
      end
    end

    def validate_structured_result_limits!(value)
      nodes = 0
      stack = [[value, 1]]
      until stack.empty?
        child, depth = stack.pop
        nodes += 1
        if depth > MAX_STRUCTURED_RESULT_DEPTH
          raise ToolError, "Structured result exceeds the maximum nesting depth"
        end
        if nodes > MAX_STRUCTURED_RESULT_NODES
          raise ToolError, "Structured result exceeds the maximum complexity"
        end

        case child
        when Hash
          child.each { |key, nested| stack << [key, depth + 1] << [nested, depth + 1] }
        when Array
          child.each { |nested| stack << [nested, depth + 1] }
        end
      end

      if JSON.generate(value).bytesize > MAX_STRUCTURED_RESULT_BYTES
        raise ToolError, "Structured result exceeds the maximum serialized size"
      end
    rescue JSON::GeneratorError
      raise ToolError, "Structured result cannot be serialized"
    end

    def redact_structured_result_message(message)
      Message.new(
        role: message.role,
        content: "[Structured result #{self.class.result_schema.fetch(:name)} redacted]",
        metadata: message.metadata
      )
    end

    def redact_structured_result_tool_message(message)
      tool_uses = message.content.grep(Content::ToolUse).map do |tool_use|
        Content::ToolUse.new(id: tool_use.id, name: tool_use.name, input: {})
      end
      Message.new(role: message.role, content: tool_uses, metadata: message.metadata)
    end

    def structured_result_diagnostic_message(message)
      return message unless @structured_output_strategy

      tool_uses = message.content.grep(Content::ToolUse)
      if tool_uses.empty?
        redact_structured_result_message(message)
      elsif structured_result_tool_uses(tool_uses).empty?
        message
      else
        redact_structured_result_tool_message(message)
      end
    end

    def publish_model_events(events, buffered_events, provider_response, response, repair:)
      redact = structured_result_terminal_response?(provider_response, repair:) ||
        structured_result_terminal_response?(response, repair:)
      buffered_events.each do |event|
        published = redact ? redact_structured_result_event(event, provider_response) : event
        events << published if published
      end
    end

    def redact_structured_result_event(event, response)
      return if %i[text_delta reasoning_delta tool_call_delta].include?(event.type)

      data = event.data
      if event.type == :message_stop
        data = data.merge(response: redact_structured_result_response(response))
      elsif event.type == :tool_call_stop && data[:tool_use]
        tool_use = data.fetch(:tool_use)
        data = data.merge(
          tool_use: Content::ToolUse.new(id: tool_use.id, name: tool_use.name, input: {})
        )
      end
      StreamEvent.build(event.type, **data)
    end

    def structured_result_stream_response(provider_response, response, repair:)
      redact = structured_result_terminal_response?(provider_response, repair:) ||
        structured_result_terminal_response?(response, repair:)
      return response unless redact

      redact_structured_result_response(response)
    end

    def structured_result_terminal_response?(response, repair:)
      return false unless @structured_output_strategy
      return true if repair

      tool_uses = response.message.content.grep(Content::ToolUse)
      return tool_uses.empty? if @structured_output_strategy.provider?

      tool_uses.empty? || !structured_result_tool_uses(tool_uses).empty?
    end

    def redact_structured_result_response(response)
      ModelResponse.new(
        message: redact_structured_result_payload_message(response.message),
        stop_reason: response.stop_reason,
        usage: response.usage,
        metadata: response.metadata
      )
    end

    def redact_structured_result_payload_message(message)
      if message.content.any? { |block| block.is_a?(Content::ToolUse) }
        redact_structured_result_tool_message(message)
      else
        redact_structured_result_message(message)
      end
    end

    def structured_result_repair_message
      requirement = if @structured_output_strategy&.tool?
        "Call #{@structured_output_strategy.schema_name} exactly once as your only tool call."
      else
        "Your final response must be JSON matching the configured output schema."
      end
      Message.new(
        role: :user,
        content: "#{requirement} You have one repair attempt. The previous structured result was invalid."
      )
    end

    def instrument_structured_result_repair(operation_id, started_at, context, validation_status:)
      instrument(
        :structured_result,
        parent_operation_id: operation_id,
        schema_name: self.class.result_schema.fetch(:name),
        strategy: structured_output_strategy_name,
        validation_status:,
        repair_attempted: true,
        duration_ms: duration_ms(started_at),
        result_duration_ms: duration_ms(started_at),
        **usage_attributes(context.usage)
      )
    end

    def complete_structured_result(
      response,
      messages,
      context,
      events,
      agent_handle:,
      turn_handle:,
      turn:,
      started_at:,
      repaired:
    )
      structured_result = context.structured_result
      raise ProtocolError, "Structured output completed without capturing a result" unless structured_result

      result = RunResult.new(
        message: messages[-1],
        stop_reason: :structured_result,
        usage: context.usage,
        messages: messages.freeze,
        state: context.state,
        structured_result:
      )
      decision = run_callbacks(:after_invocation, {result: result}, context: context)
      apply_cancellation_decision!(decision)
      result = replacement_value(decision, :result, result)
      context.checkpoint(result.messages)
      instrument(
        :structured_result,
        schema_name: structured_result.schema_name,
        strategy: structured_output_strategy_name,
        validation_status: :valid,
        repair_attempted: repaired,
        duration_ms: duration_ms(started_at),
        result_duration_ms: duration_ms(started_at),
        **usage_attributes(result.usage)
      )
      finish_instrumentation(
        turn_handle,
        outcome: :completed,
        turn:
      )
      metadata = model.details.to_h.merge(model_role: model.role)
      finish_instrumentation(
        agent_handle,
        outcome: :completed,
        duration_ms: duration_ms(started_at),
        stop_reason: result.stop_reason,
        diagnostic: {output: diagnostic_message(result.message)},
        **usage_attributes(result.usage)
      )
      emit(events, :invocation_stop, result:, metadata:)
      result
    end

    def raise_structured_result_error!(
      message,
      context,
      operation_id:,
      started_at:,
      validation_errors:,
      repair_attempted: true
    )
      configuration = self.class.result_schema
      instrument(
        :structured_result,
        parent_operation_id: operation_id,
        schema_name: configuration.fetch(:name),
        strategy: structured_output_strategy_name,
        validation_status: :failed,
        repair_attempted:,
        duration_ms: duration_ms(started_at),
        result_duration_ms: duration_ms(started_at),
        **usage_attributes(context.usage)
      )
      raise StructuredResultError.new(
        message,
        schema_name: configuration.fetch(:name),
        validation_errors:
      )
    end

    def structured_output_strategy_name
      @structured_output_strategy&.tool? ? :tool : :provider
    end

    def rendered_system_prompt(locals, invocation_paths)
      prompt = self.class.system_prompt
      prompt = prompt.call(locals) if prompt.respond_to?(:call)
      return append_code_mode_instructions(prompt) if prompt
      template = self.class.system_template
      return append_code_mode_instructions(DEFAULT_SYSTEM_PROMPT) if instance_of?(Agent) && run && !template

      template ||= "#{self.class.logical_path}/system" if run
      return nil unless template

      append_code_mode_instructions(@template_resolver.render(
        template,
        locals: locals,
        invocation_paths: invocation_paths
      ))
    end

    def initialize_code_mode
      declaration = self.class.code_mode_configuration
      return unless declaration

      defaults = @runtime&.code_mode_configuration
      @code_mode_declaration = (defaults || {}).merge(declaration).transform_keys(&:to_sym).freeze
      unknown = @code_mode_declaration.keys - %i[engine except sandbox limits]
      raise ConfigurationError, "Unknown code-mode option: #{unknown.first.inspect}" unless unknown.empty?
      @code_mode_runtime = CodeMode::AgentRuntime.new(agent: self, declaration: @code_mode_declaration)
      @tool_registry.register(CodeMode::ExecTool)
      @tool_registry.register(CodeMode::WaitTool)
      @tool_registry.register(CodeMode::StopTool)
    end

    def append_code_mode_instructions(prompt)
      return prompt unless @code_mode_runtime

      [prompt, @code_mode_runtime.instructions].compact.reject(&:empty?).join("\n\n")
    end

    def default_template_resolver(paths)
      LittleGhost::PromptResolver.new(paths:)
    end

    def apply_cancellation_decision!(decision)
      raise CancelledError, decision.reason if decision.cancel?
    end

    def replacement_value(decision, key, fallback)
      return fallback unless decision.replace?

      value = decision.value
      value.is_a?(Hash) ? value.fetch(key, fallback) : value
    end

    def run_callbacks(name, payload, context: nil)
      self.class.callbacks.run(name, payload, context:, receiver: self)
    end

    def emit(events, type, **data)
      events << StreamEvent.build(type, **data)
    end

    def agent_stream_events(events, input:, operation_id:, parent_operation_id:)
      return events unless run&.include_agent_events?

      source = AgentStreamSource.build(
        agent_id: self.class.agent_id,
        agent_path:,
        operation_id:,
        parent_operation_id:,
        assembly_path: agent_stream_path
      )
      AgentStreamSink.new(destination: events, run:, source:, input:)
    end

    def instrument(name, **attributes)
      attributes.delete(:diagnostic) unless self.class.capture_diagnostics
      values = correlation_attributes.merge(attributes.compact)
      Instrumentation.publish(name, **values)
    end

    def start_instrumentation(name, **attributes)
      attributes.delete(:diagnostic) unless self.class.capture_diagnostics
      Instrumentation.start(name, **correlation_attributes.merge(attributes.compact))
    end

    def active_instrumentation_parent
      current = Instrumentation.current
      current if current&.active?
    end

    def finish_instrumentation(handle, **attributes)
      return unless handle

      attributes.delete(:diagnostic) unless self.class.capture_diagnostics
      handle.finish(**correlation_attributes.merge(attributes.compact))
    end

    def correlation_attributes
      return {agent_id: self.class.agent_id} unless run

      {
        run_id: run.invocation.run_id,
        invocation_id: run.invocation.invocation_id,
        session_id: run.invocation.session_id,
        agent_id: self.class.agent_id
      }
    end

    def model_attributes
      {
        model_id: model.model_id,
        model_role: model.role,
        model_provider: model.target.provider
      }.compact
    end

    def response_attributes(response)
      metadata = response.metadata.to_h
      response_id = metadata[:id] || metadata["id"]
      response_model = metadata[:model] || metadata["model"]
      {
        response_id:,
        response_model:,
        finish_reasons: response.stop_reason ? [response.stop_reason.to_s] : nil
      }.compact
    end

    def provider_error_attributes(error)
      status = error.respond_to?(:status) ? error.status : nil
      {http_response_status_code: status}.compact
    end

    def usage_attributes(usage)
      usage.respond_to?(:to_h) ? usage.to_h : {}
    end

    def model_output_event?(event)
      %i[text_delta reasoning_delta tool_call_start tool_call_delta].include?(event.type)
    end

    def diagnostic_input(value)
      value.is_a?(Message) ? diagnostic_message(value) : value
    end

    def diagnostic_tool_input(tool_use)
      tool_use.input
    end

    def diagnostic_message(message)
      {
        role: message.role,
        content: message.content.map { |block| diagnostic_content(block) }
      }
    end

    def diagnostic_content(block)
      case block
      when Content::Text
        {type: "text", text: block.text}
      when Content::Reasoning
        {type: "reasoning", text: block.text}
      when Content::Image
        {type: "image", media_type: block.media_type, bytes: block.data.bytesize}
      when Content::Document
        {type: "document", media_type: block.media_type, name: block.name, bytes: block.data.bytesize}
      when Content::ToolUse
        {type: "tool_use", id: block.id, name: block.name, input: diagnostic_tool_input(block)}
      when Content::ToolResult
        {
          type: "tool_result", tool_use_id: block.tool_use_id,
          content: diagnostic_tool_result(block), status: block.status
        }
      else
        block.to_s
      end
    end

    def diagnostic_tool_result(result, **)
      value = result.respond_to?(:content) ? result.content : result
      return value.map { |block| block.respond_to?(:role) ? diagnostic_message(block) : block.to_s } if value.is_a?(Array)

      value.respond_to?(:role) ? diagnostic_message(value) : value.to_s
    end

    def artifact_presentation_message?(message)
      message.metadata[:little_ghost_artifact_presentation] || message.metadata["little_ghost_artifact_presentation"]
    end

    def diagnostic_tool_exception(error, tool:)
      diagnostic_exception(error).merge(message: truncated_tool_result(error.message))
    end

    def diagnostic_exception(error)
      {
        type: error.class.name,
        message: error.message,
        stacktrace: Array(error.backtrace).join("\n")
      }
    end

    def truncated_tool_result(content)
      Support::OutputTruncation.truncate_middle_with_token_budget(content, @max_tool_result_tokens).first
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def duration_ms(started_at)
      ((monotonic_time - started_at) * 1_000).round(3)
    end

    def duration_seconds(started_at)
      (monotonic_time - started_at).round(6)
    end
  end
end

require_relative "agent/skills"
require_relative "agent/tool_loop"
require_relative "agent/context_management"
require_relative "agent/delegation"

LittleGhost::Agent.include(
  LittleGhost::Agent::Delegation,
  LittleGhost::Agent::Skills,
  LittleGhost::Agent::ContextManagement,
  LittleGhost::Agent::ToolLoop
)
