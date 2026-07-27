# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Agent
    UNSET = Object.new.freeze
    MAX_STRUCTURED_RESULT_BYTES = 1_000_000
    MAX_STRUCTURED_RESULT_DEPTH = 64
    MAX_STRUCTURED_RESULT_NODES = 100_000
    RESULT_SCHEMA_KEYWORDS = %w[
      $schema title description type enum minimum maximum minLength maxLength
      properties required additionalProperties minItems maxItems items
    ].freeze
    CALLBACKS = %i[
      after_initialize
      before_invocation after_invocation
      before_model after_model after_model_error
      before_tool after_tool
    ].freeze

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@agent_id, @agent_id)
        subclass.instance_variable_set(:@agent_description, @agent_description)
        subclass.instance_variable_set(:@system_template, @system_template)
        subclass.instance_variable_set(:@system_prompt, @system_prompt)
        subclass.instance_variable_set(:@system_prompt_builder, @system_prompt_builder)
        subclass.instance_variable_set(:@model_role, @model_role)
        subclass.instance_variable_set(:@result_schema_configuration, @result_schema_configuration)
        subclass.instance_variable_set(:@capture_diagnostics, @capture_diagnostics)
        subclass.instance_variable_set(:@limits, limits.dup)
      end

      def agent_id(value = nil)
        return @agent_id || default_agent_id if value.nil?

        @agent_id = Support.immutable(value.to_s)
      end

      def logical_path
        parts = name.to_s.split("::")
        parts[-1] = parts.last.sub(/Agent\z/, "") if parts.any?
        parts.reject(&:empty?).map { |part| underscore(part) }.join("/")
      end

      def description(value = nil)
        return @agent_description.to_s if value.nil?

        @agent_description = Support.immutable(value.to_s)
      end

      def model(value = nil, &block)
        @model_role = block || Support.immutable(value.to_s) unless value.nil? && !block
        @model_role
      end

      def model_role(invocation)
        value = @model_role
        resolved = value.respond_to?(:call) ? value.call(invocation) : value
        resolved&.to_s
      end

      def limits(**values)
        @limits = Support.immutable(limits.merge(values.transform_keys(&:to_sym))) unless values.empty?
        @limits ||= {}.freeze
      end

      def result_schema(schema = UNSET, name: nil, description: nil, strategy: :auto, **schema_keywords)
        if schema.equal?(UNSET)
          return @result_schema_configuration if schema_keywords.empty?

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

        @result_schema_configuration = Support.immutable(
          schema: normalized_schema,
          name: schema_name,
          description: description&.to_s,
          strategy:
        )
      end

      def capture_diagnostics(value = UNSET)
        return @capture_diagnostics != false if value.equal?(UNSET)

        @capture_diagnostics = value == true
      end

      def system_template(value = nil)
        return @system_template if value.nil?

        @system_template = Support.immutable(value.to_s)
      end

      def system_prompt(value = nil, &block)
        return @system_prompt_builder || @system_prompt if value.nil? && !block

        @system_template = nil
        if block
          @system_prompt = nil
          @system_prompt_builder = block
        else
          @system_prompt = Support.immutable(value.to_s)
          @system_prompt_builder = nil
        end
      end

      def tools(*values, &resolver)
        invalid = values.flatten.compact.find { |value| !value.is_a?(Class) || !(value <= Tool) }
        if invalid
          raise ConfigurationError,
            "Class-level tools must be LittleGhost::Tool classes; use a block for per-agent tool instances"
        end

        local_tool_declarations.concat(values.map { |value| Support.immutable(value) })
        local_tool_declarations << resolver if resolver
        tool_declarations
      end

      def tool_declarations
        inherited = superclass.respond_to?(:tool_declarations) ? superclass.tool_declarations : []
        inherited + local_tool_declarations
      end

      def prompt_local(name, value = UNSET, &resolver)
        raise ArgumentError, "Provide a prompt local value or block" if value.equal?(UNSET) && !resolver
        raise ArgumentError, "Provide a prompt local value or block, not both" unless value.equal?(UNSET) || !resolver

        local_prompt_locals[name.to_sym] = resolver || Support.immutable(value)
      end

      def prompt_local_resolvers
        inherited = superclass.respond_to?(:prompt_local_resolvers) ? superclass.prompt_local_resolvers : {}
        inherited.merge(local_prompt_locals).freeze
      end

      def callbacks
        inherited = if superclass.respond_to?(:callbacks)
          superclass.callbacks
        else
          Support::Callbacks.new(*CALLBACKS)
        end
        inherited.merge(local_callbacks)
      end

      CALLBACKS.each do |name|
        define_method(name) do |callable = nil, prepend: false, &block|
          local_callbacks.on(name, callable, prepend:, &block)
          self
        end
      end

      private

      def local_callbacks
        @callbacks ||= Support::Callbacks.new(*CALLBACKS)
      end

      def local_prompt_locals
        @prompt_locals ||= {}
      end

      def local_tool_declarations
        @tool_declarations ||= []
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

      def default_agent_id
        value = name.to_s.split("::").last.to_s.gsub(/Agent\z/, "").gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
        (value.empty? ? "agent" : value).freeze
      end

      def underscore(value)
        value.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end
    end

    attr_reader :model, :tool_registry, :instrumentation, :run

    def initialize(
      model:,
      tools: [],
      instrumentation: nil,
      template_resolver: nil,
      template_paths: [],
      run: nil,
      executor: Support::Executor.new,
      max_turns: 100,
      max_tool_calls: 1_000,
      model_settings: {}
    )
      @model = model
      @run = run
      @tool_registry = ToolRegistry.new(tools, run:)
      self.class.tool_declarations.each do |declaration|
        resolved = if declaration.is_a?(Proc) && declaration.parameters.empty?
          instance_exec(&declaration)
        else
          declaration
        end
        @tool_registry.register(resolved, replace: true)
      end
      @structured_output_strategy = StructuredOutput.resolve(
        self.class.result_schema,
        model:,
        ordinary_tools: @tool_registry.specifications
      )
      @instrumentation = instrumentation || Support::Instrumentation.new
      @model_settings = model_settings.to_h.freeze
      @template_resolver = template_resolver || default_template_resolver(template_paths)
      @executor = executor
      @max_turns = Integer(max_turns)
      @max_tool_calls = Integer(max_tool_calls)
      @closed = false
      @close_mutex = Mutex.new
      @exclusive_tools_mutex = Mutex.new
      @interruptions_mutex = Mutex.new
      @active_interruptions = []
      raise ArgumentError, "max_turns must be at least 1" if @max_turns < 1
      raise ArgumentError, "max_tool_calls must be at least 1" if @max_tool_calls < 1
      apply_cancellation_decision!(run_callbacks(:after_initialize, self))
    rescue
      @tool_registry&.close
      raise
    end

    def call(input = UNSET, **options)
      result = nil
      stream(input, **options).each do |event|
        result = event.data[:result] if event.type == :invocation_stop
      end
      result
    end

    def interrupt(
      message,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      target_operation_id: nil
    )
      unless message.is_a?(String)
        raise ArgumentError, "interrupt message must be a string"
      end

      interruptions = @interruptions_mutex.synchronize do
        active = if target_operation_id
          @active_interruptions.select { |candidate| candidate.target_operation_id == target_operation_id }
        else
          @active_interruptions
        end
        if active.empty?
          raise AgentInterruptError, "Agent is not currently running"
        end
        if active.length > 1
          raise AgentInterruptError, "Agent has multiple active invocations; the interruption target is ambiguous"
        end

        active.first
      end
      ticket = interruptions.enqueue(message)
      instrument(
        :agent_interrupt_queued,
        parent_operation_id: interruptions.operation_id,
        interruption_id: ticket.id,
        event_kind: :interrupt,
        diagnostic: {input: message}
      )
      begin
        ticket.value(cancellation_token:, deadline:)
      rescue => error
        interruptions.withdraw(ticket)
        instrument(
          :agent_interrupt_failed,
          parent_operation_id: interruptions.operation_id,
          interruption_id: ticket.id,
          event_kind: :interrupt,
          error_type: error.class.name,
          diagnostic: {exception: diagnostic_exception(error)}
        )
        raise
      end
    end

    def stream(
      input = UNSET,
      history: UNSET,
      context: UNSET,
      cancellation_token: Support::CancellationToken.new,
      deadline: nil,
      settings: UNSET,
      template_locals: UNSET,
      template_paths: UNSET,
      parent_operation_id: nil,
      checkpoint: nil
    )
      raise ArgumentError, "input is required" if input.equal?(UNSET)

      history = [] if history.equal?(UNSET)
      context = {} if context.equal?(UNSET)
      settings = {} if settings.equal?(UNSET)
      template_locals = {} if template_locals.equal?(UNSET)
      template_paths = [] if template_paths.equal?(UNSET)
      invocation_paths = Array(template_paths).map do |path|
        unless path.is_a?(Templates::TrustedPath)
          raise ArgumentError, "invocation template paths must be LittleGhost::Templates::TrustedPath values"
        end
        path
      end
      settings = @model_settings.merge(settings)
      Enumerator.new do |events|
        interruptions = AgentInterruptions.new
        run_context = RunContext.new(
          state: context,
          cancellation_token: cancellation_token,
          deadline: deadline,
          instrumentation: instrumentation,
          metadata: {agent_id: self.class.agent_id},
          checkpoint:
        )
        begin
          execute(
            input,
            history: history,
            context: run_context,
            settings: settings,
            template_locals: template_locals,
            template_paths: invocation_paths,
            events: events,
            parent_operation_id:,
            interruptions:
          )
        rescue => error
          interruptions.close(error)
          raise
        ensure
          interruptions.close(AgentInterruptError.new("Agent finished before the interruption was delivered"))
          unregister_interruptions(interruptions)
        end
      end
    end

    def as_tool(name: self.class.agent_id, description: self.class.description, preserve_context: false)
      agent = self
      description = "Delegate a task to #{name}." if description.to_s.empty?
      mutex = Mutex.new
      retained_history = []
      tool_class = Tool.define(
        name: name,
        description: description,
        input_schema: {
          type: "object",
          properties: {input: {type: "string"}},
          required: ["input"],
          additionalProperties: false
        }
      ) do |input, context: nil|
        invocation = lambda do
          result = agent.call(
            input.fetch("input"),
            history: preserve_context ? retained_history : [],
            context: context&.state || {},
            cancellation_token: context&.cancellation_token || Support::CancellationToken.new,
            deadline: context&.deadline,
            parent_operation_id: run&.operation_id
          )
          retained_history.replace(result.messages.reject { |message| message.role == :system }) if preserve_context
          result.structured? ? result.structured_result.value : result.text
        end
        preserve_context ? mutex.synchronize(&invocation) : invocation.call
      end
      tool_class.define_method(:close) { agent.close }
      tool_class.new(run: run)
    end

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

    def tools = tool_registry

    def close
      resources, interruptions = @close_mutex.synchronize do
        return if @closed

        @closed = true
        [
          [tool_registry],
          @interruptions_mutex.synchronize { @active_interruptions.dup }
        ]
      end
      first_error = nil
      interruptions.each do |active|
        active.close(AgentInterruptError.new("Agent was closed"))
      end
      resources.each do |resource|
        resource.close if resource.respond_to?(:close)
      rescue => error
        first_error ||= error
      end
      raise first_error if first_error
    end

    private

    def register_interruptions(interruptions)
      @interruptions_mutex.synchronize { @active_interruptions << interruptions }
    end

    def unregister_interruptions(interruptions)
      @interruptions_mutex.synchronize { @active_interruptions.delete(interruptions) }
    end

    def interruption_message(interruption)
      Message.new(
        role: :user,
        content: <<~MESSAGE.strip,
          Agent interruption:
          #{interruption.message}

          Respond briefly in ordinary text before any tool calls, then continue the current task unless this
          interruption asks you to finish.
        MESSAGE
        metadata: {little_ghost_interruption_id: interruption.id}
      )
    end

    def request_with_interruption(request, interruption)
      ModelRequest.new(
        messages: [*request.messages, interruption_message(interruption)],
        tools: request.tools,
        settings: request.settings,
        output_schema: nil,
        tool_choice: nil,
        required_capabilities: request.tools.empty? ? [] : [:tools],
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
    end

    def request_contains_interruption?(request, interruption)
      request.messages.any? do |message|
        message.metadata[:little_ghost_interruption_id] == interruption.id
      end
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
      interruptions:
    )
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
      context.bind_agent_operation_id(operation_id)
      interruptions.bind(operation_id, target_operation_id: parent_operation_id)
      register_interruptions(interruptions)
      instrument(
        :agent_start,
        operation_id:,
        parent_operation_id:,
        available_tools: tool_registry.names,
        diagnostic: {input: diagnostic_input(input)}
      )
      context.check!
      messages = history.map { |message| Message.coerce(message) }
      prompt = rendered_system_prompt(template_locals, template_paths)
      messages.unshift(Message.new(role: :system, content: prompt)) unless prompt.to_s.empty?
      messages << (input.is_a?(Message) ? input : Message.new(role: :user, content: input))
      tool_call_count = 0
      structured_result_repair_due = false

      decision = run_callbacks(:before_invocation, {messages: messages}, context: context)
      apply_cancellation_decision!(decision)
      messages = replacement_value(decision, :messages, messages)
      context.checkpoint(messages)
      emit(events, :invocation_start, agent_id: self.class.agent_id)

      @max_turns.times do |turn|
        turn_operation_id = SecureRandom.uuid
        instrument(
          :agent_turn_start,
          operation_id: turn_operation_id,
          parent_operation_id: operation_id,
          turn: turn + 1
        )
        begin
          context.check!
          response, interrupted = invoke_model(
            messages,
            context,
            settings,
            turn,
            events,
            parent_operation_id: turn_operation_id,
            structured_result_repair_due:,
            interruptions:
          )
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
              unless interruptions.finish
                context.checkpoint(messages)
                instrument(
                  :agent_turn_stop,
                  operation_id: turn_operation_id,
                  outcome: :interrupted,
                  turn: turn + 1
                )
                next
              end
              return complete_structured_result(
                response,
                messages,
                context,
                events,
                operation_id:,
                turn_operation_id:,
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
            instrument(
              :agent_turn_stop,
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

            if interrupted || !@structured_output_strategy
              unless interruptions.finish
                context.checkpoint(messages)
                instrument(
                  :agent_turn_stop,
                  operation_id: turn_operation_id,
                  outcome: :interrupted,
                  turn: turn + 1
                )
                next
              end
            end

            if @structured_output_strategy && !interrupted
              validation_error = if @structured_output_strategy.provider?
                capture_structured_result(response.message.text, context)
              else
                "The structured result tool was not called"
              end
              unless validation_error
                messages[-1] = redact_structured_result_message(response.message)
                unless interruptions.finish
                  context.checkpoint(messages)
                  instrument(
                    :agent_turn_stop,
                    operation_id: turn_operation_id,
                    outcome: :interrupted,
                    turn: turn + 1
                  )
                  next
                end
                return complete_structured_result(
                  response,
                  messages,
                  context,
                  events,
                  operation_id:,
                  turn_operation_id:,
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
              instrument(
                :agent_turn_stop,
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
            instrument(
              :agent_turn_stop,
              operation_id: turn_operation_id,
              outcome: :completed,
              turn: turn + 1
            )
            metadata = model.respond_to?(:metadata) ? model.metadata : {}
            instrument(
              :agent_stop,
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

          tool_call_count += tool_uses.length
          raise ProtocolError, "The agent reached its maximum tool calls" if tool_call_count > @max_tool_calls

          tool_results = execute_tools(
            tool_uses,
            context,
            events,
            parent_operation_id: turn_operation_id
          )
          messages << Message.new(
            role: :tool,
            content: tool_results
          )
          context.checkpoint(messages)
          instrument(
            :agent_turn_stop,
            operation_id: turn_operation_id,
            outcome: :completed,
            turn: turn + 1
          )
        rescue => error
          instrument(
            :agent_turn_stop,
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
      instrument(
        :agent_stop,
        operation_id:,
        outcome: :error,
        duration_ms: duration_ms(started_at),
        error_type: error.class.name,
        diagnostic: {exception: diagnostic_exception(error)},
        **usage_attributes(context.usage)
      )
      metadata = model.respond_to?(:metadata) ? model.metadata : {}
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
      interruptions:,
      structured_result_repair_due: false,
      recovery_attempt: 0,
      interruption: nil
    )
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
      strategy = @structured_output_strategy
      ordinary_tools = tool_registry.specifications
      StructuredOutput.validate_tool_collision!(strategy, ordinary_tools) if strategy
      request = ModelRequest.new(
        messages: messages,
        tools: strategy ? strategy.tools(ordinary_tools) : ordinary_tools,
        settings: settings,
        output_schema: strategy&.output_schema,
        tool_choice: strategy&.tool_choice(repair: structured_result_repair_due),
        required_capabilities: strategy&.required_capabilities || [],
        cancellation_token: context.cancellation_token,
        deadline: context.deadline
      )
      decision = run_callbacks(
        :before_model,
        {request: request, turn: turn, parent_operation_id:},
        context: context
      )
      apply_cancellation_decision!(decision)
      request = replacement_value(decision, :request, request)
      interruption ||= interruptions.deliver
      if interruption && !request_contains_interruption?(request, interruption)
        request = request_with_interruption(request, interruption)
        instrument(
          :agent_interrupt_delivered,
          parent_operation_id: operation_id,
          interruption_id: interruption.id,
          event_kind: :interrupt
        )
      end
      messages.replace(request.messages)
      context.checkpoint(messages)
      instrument(
        :model_start,
        operation_id:,
        parent_operation_id:,
        turn:,
        diagnostic: {
          input: request.messages.map { |message| diagnostic_message(message) },
          tool_definitions: request.tools
        },
        model_settings: request.settings,
        **model_attributes
      )
      emit(events, :model_start, turn: turn)
      response = nil
      time_to_first_token = nil
      buffered_events = strategy ? [] : nil

      model.stream(request).each do |event|
        context.check!
        time_to_first_token ||= duration_seconds(started_at) if model_output_event?(event)
        if event.type == :model_retry
          response = nil
          instrument(
            :model_retry,
            parent_operation_id: operation_id,
            attempt: event.data[:attempt],
            delay: event.data[:delay],
            error_class: event.data[:error_class],
            **model_attributes
          )
        end
        buffered_events ? buffered_events << event : events << event
        response = event.data[:response] if event.type == :message_stop
      end
      raise ProtocolError, "The model stream ended without a response" unless response

      context.record_usage(response.usage)
      provider_response = response

      decision = run_callbacks(:after_model, {request: request, response: response, turn: turn}, context: context)
      apply_cancellation_decision!(decision)
      response = replacement_value(decision, :response, response)
      interruptions.resolve(interruption, response.message.text)
      if interruption
        instrument(
          :agent_interrupt_responded,
          parent_operation_id: operation_id,
          interruption_id: interruption.id,
          event_kind: :interrupt,
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
      instrument(
        :model_stop,
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
      [response, !interruption.nil?]
    rescue => error
      instrument(
        :model_stop,
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
            interruptions:,
            interruption:
          )
        end
      end
      raise
    end

    def execute_tools(tool_uses, context, events, parent_operation_id:)
      if tool_uses.map(&:id).uniq.length != tool_uses.length
        raise ProtocolError, "The model returned duplicate tool use ids"
      end

      tool_uses.each { |tool_use| emit(events, :tool_start, tool_use: tool_use) }
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
        instrument(
          :tool_start,
          operation_id:,
          parent_operation_id:,
          tool_name: telemetry_tool_name,
          tool_type: "function",
          tool_call_id: tool_use.id,
          diagnostic: {
            input: diagnostic_tool_input(tool_use),
            tool_definitions: tool.is_a?(Tool) ? [tool.specification] : []
          }
        )
        if tool.is_a?(ToolError)
          result = Content::ToolResult.new(tool_use_id: tool_use.id, content: tool.message, status: :error)
          instrument(
            :tool_stop,
            operation_id:,
            parent_operation_id:,
            tool_name: telemetry_tool_name,
            outcome: :error,
            duration_ms: duration_ms(started_at),
            error_type: tool.class.name,
            diagnostic: {
              output: diagnostic_tool_result(result, tool:),
              exception: diagnostic_exception(tool)
            }
          )
          next result
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
          result = Content::ToolResult.new(
            tool_use_id: tool_use.id,
            content: decision.reason,
            status: :error
          )
          instrument(
            :tool_stop,
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
          next result
        end

        tool_result = if tool.exclusive?
          synchronize_exclusive_tools { tool.execute(tool_use.input, context: context) }
        else
          tool.execute(tool_use.input, context: context)
        end
        after_decision = run_callbacks(
          :after_tool,
          callback_payload.merge(result: tool_result),
          context: context
        )
        tool_result = replacement_value(after_decision, :result, tool_result)
        result = Content::ToolResult.new(
          tool_use_id: tool_use.id,
          content: tool_result.content,
          status: tool_result.status
        )
        tool_error = tool_result.error
        tool_error ||= ToolError.new(tool_result.content) if result.status == :error
        instrument(
          :tool_stop,
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
        result
      rescue ToolError => error
        result = Content::ToolResult.new(tool_use_id: tool_use.id, content: error.message, status: :error)
        instrument(
          :tool_stop,
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
        result
      rescue => error
        instrument(
          :tool_stop,
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
          result = execution.call(tool_use, tool)
          emit(events, :tool_stop, tool_use:, result:)
          result
        end
      else
        @executor.map(
          pairs,
          cancellation_token: context.cancellation_token,
          on_result: lambda do |index, result|
            emit(events, :tool_stop, tool_use: tool_uses.fetch(index), result:)
          end
        ) do |tool_use, tool|
          execution.call(tool_use, tool)
        end
      end
    end

    def synchronize_exclusive_tools(&block)
      if run
        run.synchronize_exclusive_tools(&block)
      else
        @exclusive_tools_mutex.synchronize(&block)
      end
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
        StructuredResult.new(schema_name:, value: Support.immutable(value))
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
        Content::ToolResult.new(
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
      operation_id:,
      turn_operation_id:,
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
        parent_operation_id: operation_id,
        schema_name: structured_result.schema_name,
        strategy: structured_output_strategy_name,
        validation_status: :valid,
        repair_attempted: repaired,
        duration_ms: duration_ms(started_at),
        result_duration_ms: duration_ms(started_at),
        **usage_attributes(result.usage)
      )
      instrument(
        :agent_turn_stop,
        operation_id: turn_operation_id,
        outcome: :completed,
        turn:
      )
      metadata = model.respond_to?(:metadata) ? model.metadata : {}
      instrument(
        :agent_stop,
        outcome: :completed,
        duration_ms: duration_ms(started_at),
        stop_reason: result.stop_reason,
        operation_id:,
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
      return prompt.call(locals) if prompt.respond_to?(:call)
      return prompt if prompt
      template = self.class.system_template
      template ||= "#{self.class.logical_path}/system" if run
      return nil unless template

      @template_resolver.render(
        template,
        locals: locals,
        invocation_paths: invocation_paths
      )
    end

    def default_template_resolver(paths)
      return unless defined?(Templates::Resolver)

      Templates::Resolver.new(application_paths: paths)
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

    def instrument(name, **attributes)
      attributes.delete(:diagnostic) unless self.class.capture_diagnostics
      instrumentation.emit(name, **correlation_attributes, **attributes.compact)
    end

    def correlation_attributes
      return {agent_id: self.class.agent_id} unless run

      {
        parent_operation_id: run.operation_id,
        run_id: run.invocation.run_id,
        invocation_id: run.invocation.invocation_id,
        session_id: run.invocation.session_id,
        agent_id: self.class.agent_id
      }.merge(
        run.application.respond_to?(:instrumentation_attributes) ?
          run.application.instrumentation_attributes(run:, agent: self) : {}
      )
    end

    def model_attributes
      {
        model_id: model.respond_to?(:id) ? model.id : nil,
        model_role: model.respond_to?(:role) ? model.role : nil,
        model_provider: model.respond_to?(:provider_name) ? model.provider_name : model.class.name
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

    def diagnostic_tool_exception(error, tool:) = diagnostic_exception(error)

    def diagnostic_exception(error)
      {
        type: error.class.name,
        message: error.message,
        stacktrace: Array(error.backtrace).join("\n")
      }
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
require_relative "agent/tool_result_offloading"
require_relative "agent/context_management"
require_relative "agent/delegation"

LittleGhost::Agent.include(
  LittleGhost::Agent::Delegation,
  LittleGhost::Agent::Skills,
  LittleGhost::Agent::ToolResultOffloading,
  LittleGhost::Agent::ContextManagement,
  LittleGhost::Agent::ToolLoop
)
