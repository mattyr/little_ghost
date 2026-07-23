# frozen_string_literal: true

require "securerandom"

module LittleGhost
  class Agent
    UNSET = Object.new.freeze
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
      @instrumentation = instrumentation || Support::Instrumentation.new
      @model_settings = model_settings.to_h.freeze
      @template_resolver = template_resolver || default_template_resolver(template_paths)
      @executor = executor
      @max_turns = Integer(max_turns)
      @max_tool_calls = Integer(max_tool_calls)
      @closed = false
      @close_mutex = Mutex.new
      @exclusive_tools_mutex = Mutex.new
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
        run_context = RunContext.new(
          state: context,
          cancellation_token: cancellation_token,
          deadline: deadline,
          instrumentation: instrumentation,
          metadata: {agent_id: self.class.agent_id},
          checkpoint:
        )
        execute(
          input,
          history: history,
          context: run_context,
          settings: settings,
          template_locals: template_locals,
          template_paths: invocation_paths,
          events: events,
          parent_operation_id:
        )
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
          result.text
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
      resources = @close_mutex.synchronize do
        return if @closed

        @closed = true
        [tool_registry]
      end
      first_error = nil
      resources.each do |resource|
        resource.close if resource.respond_to?(:close)
      rescue => error
        first_error ||= error
      end
      raise first_error if first_error
    end

    private

    def execute(input, history:, context:, settings:, template_locals:, template_paths:, events:, parent_operation_id:)
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
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
          response = invoke_model(
            messages,
            context,
            settings,
            turn,
            events,
            parent_operation_id: turn_operation_id
          )
          messages << response.message
          tool_uses = response.message.content.grep(Content::ToolUse)

          if tool_uses.empty?
            context.checkpoint(messages)
            if %i[max_tokens limit_output_tokens limit_total_tokens limit_turns].include?(response.stop_reason)
              raise OutputLimitError, "The model stopped before completing its response"
            end

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

          tool_call_count += tool_uses.length
          raise ProtocolError, "The agent reached its maximum tool calls" if tool_call_count > @max_tool_calls

          tool_results = execute_tools(
            tool_uses,
            context,
            events,
            parent_operation_id: turn_operation_id
          )
          messages << Message.new(role: :tool, content: tool_results)
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

    def invoke_model(messages, context, settings, turn, events, parent_operation_id:, recovery_attempt: 0)
      started_at = monotonic_time
      operation_id = SecureRandom.uuid
      request = ModelRequest.new(
        messages: messages,
        tools: tool_registry.specifications,
        settings: settings,
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
        events << event
        response = event.data[:response] if event.type == :message_stop
      end
      raise ProtocolError, "The model stream ended without a response" unless response

      context.record_usage(response.usage)

      decision = run_callbacks(:after_model, {request: request, response: response, turn: turn}, context: context)
      apply_cancellation_decision!(decision)
      response = replacement_value(decision, :response, response)
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
        diagnostic: {output: diagnostic_message(response.message)},
        **model_attributes,
        **usage_attributes(response.usage)
      )
      emit(events, :model_stop, turn: turn, response: response)
      response
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
            recovery_attempt: recovery_attempt + 1
          )
        end
      end
      raise
    end

    def execute_tools(tool_uses, context, events, parent_operation_id:)
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
          tool_call_id: tool_use.id,
          diagnostic: {input: tool_use.input}
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
              output: diagnostic_tool_result(result),
              exception: diagnostic_exception(tool)
            }
          )
          next result
        end

        context.check!

        decision = run_callbacks(:before_tool, {tool_use: tool_use, tool: tool}, context: context)
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
              output: diagnostic_tool_result(result),
              exception: diagnostic_exception(rejection)
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
          {tool_use: tool_use, tool: tool, result: tool_result},
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
            output: diagnostic_tool_result(result),
            exception: tool_error && diagnostic_exception(tool_error)
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
            output: diagnostic_tool_result(result),
            exception: diagnostic_exception(error)
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
          diagnostic: {exception: diagnostic_exception(error)}
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

    def usage_attributes(usage)
      usage.respond_to?(:to_h) ? usage.to_h : {}
    end

    def model_output_event?(event)
      %i[text_delta reasoning_delta tool_call_start tool_call_delta].include?(event.type)
    end

    def diagnostic_input(value)
      value.is_a?(Message) ? diagnostic_message(value) : value
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
        {type: "reasoning", text: "[REDACTED]"}
      when Content::Image
        {type: "image", media_type: block.media_type, bytes: block.data.bytesize}
      when Content::Document
        {type: "document", media_type: block.media_type, name: block.name, bytes: block.data.bytesize}
      when Content::ToolUse
        {type: "tool_use", id: block.id, name: block.name, input: block.input}
      when Content::ToolResult
        {
          type: "tool_result", tool_use_id: block.tool_use_id,
          content: diagnostic_tool_result(block), status: block.status
        }
      else
        block.to_s
      end
    end

    def diagnostic_tool_result(result)
      value = result.respond_to?(:content) ? result.content : result
      Array(value).map { |block| block.respond_to?(:role) ? diagnostic_message(block) : block.to_s }
    end

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
