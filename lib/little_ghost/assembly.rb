# frozen_string_literal: true

module LittleGhost
  # Gives one agent or a coordinated group the same callable entrypoint.
  #
  # An assembly is anything callers can invoke like one Agent. An Agent is the
  # smallest assembly because it owns one model loop. Workflow, Swarm, and Graph
  # subclasses coordinate several participants while preserving the same
  # +ask+, +stream_ask+, +call+, and +stream+ interface.
  #
  #   agent_run = CustomerSupportAgent.ask("Why is my transfer pending?")
  #   graph_run = SupportFlowGraph.ask("Why is my transfer pending?")
  #
  #   agent_run.response
  #   graph_run.response
  #
  # Named subclasses are the usual form. +to_builder+ creates a mutable dynamic
  # definition seeded by the class, while +definition+ returns the immutable
  # snapshot used for one execution. Composite results expose Assembly::Step
  # records through RunResult#trajectory.
  #
  # A standalone assembly owns a top-level Run. An assembly built by a Runtime
  # participates in the existing run and returns a RunResult. Applications
  # normally subclass Agent, Workflow, Swarm, or Graph rather than Assembly
  # directly. Standalone calls automatically reuse the active Configuration's
  # shared Runtime while keeping each Run and its resources independent.
  #
  # == What each calling form returns
  #
  # [<tt>CustomerSupportAgent.ask(...)</tt>]
  #   A named class creates and returns a top-level Run.
  # [<tt>CustomerSupportAgent.new(runtime: runtime).ask(...)</tt>]
  #   A standalone instance also creates and returns a top-level Run.
  # [<tt>runtime.build_assembly(..., run: run).call(...)</tt>]
  #   A participant already bound to a Run returns its child RunResult.
  # [<tt>stream_ask(...).each { |event| ... }</tt>]
  #   A standalone stream returns its top-level Run after enumeration. A
  #   run-scoped stream ends with an +invocation_stop+ event carrying RunResult.
  class Assembly
    extend Support::ClassAttributes

    class_attribute :assembly_id_value
    class_attribute :description_value

    class << self
      # Executes +message+ through a fresh standalone assembly and returns its Run.
      #
      # +options+ become Invocation fields. Common values include +history+,
      # +context+, +settings+, +metadata+, +session_id+, +actor_id+, and
      # +deadline_at+.
      def ask(message, **options)
        definition.implementation.new.ask(message, **options)
      end

      # Lazily streams +message+ through a fresh standalone assembly.
      #
      # Enumeration yields StreamEvent objects and returns the terminal Run.
      # The same Invocation fields accepted by .ask may be supplied as +options+.
      def stream_ask(message, **options)
        snapshot = definition
        stream = nil
        Enumerator.new do |events|
          stream ||= snapshot.implementation.new.stream_ask(message, **options)
          stream.each { |event| events << event }
        end
      end

      # Returns an immutable definition for this class.
      def definition
        if assembly_kind == :assembly
          implementation = dup
          implementation.assembly_id(assembly_id)
          implementation.description(description)
          implementation.freeze
          return AssemblyDefinition.new(
            kind: :assembly,
            assembly_id:,
            description:,
            implementation:
          )
        end

        to_builder.definition
      end

      # Returns a mutable dynamic builder seeded by this class.
      def to_builder
        builder_class = {
          agent: AgentBuilder,
          workflow: WorkflowBuilder,
          swarm: SwarmBuilder,
          graph: GraphBuilder
        }.fetch(assembly_kind)
        builder_class.new(base: self)
      end

      # :call-seq:
      #   assembly_id() -> String
      #   assembly_id(value) -> String
      #
      # The stable identifier used for tools and telemetry. Named subclasses
      # derive it from their underscored class name without their type suffix.
      def assembly_id(*values)
        return assembly_id_value || default_assembly_id if values.empty?

        self.assembly_id_value = values.fetch(0).to_s
      end

      # :call-seq:
      #   description() -> String
      #   description(value) -> String
      #
      # The human-readable description used when exposing the assembly as a tool.
      def description(*values)
        return description_value.to_s if values.empty?

        self.description_value = values.fetch(0).to_s
      end

      # Returns +:agent+, +:workflow+, +:swarm+, +:graph+, or +:assembly+.
      def assembly_kind
        return :agent if defined?(Agent) && self <= Agent
        return :workflow if defined?(Workflow) && self <= Workflow
        return :swarm if defined?(Swarm) && self <= Swarm
        return :graph if defined?(Graph) && self <= Graph

        :assembly
      end

      private

      def default_assembly_id
        name = self.name.to_s.split("::").last.to_s.sub(/(Agent|Workflow|Swarm|Graph)\z/, "")
        value = name.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
        (value.empty? ? assembly_kind.to_s : value).freeze
      end
    end

    # The owning Run, or +nil+ for a standalone entrypoint.
    attr_reader :run
    # Runtime used to resolve participants and build Runs.
    attr_reader :runtime
    # Workspace supplied to this Assembly, when present.
    attr_reader :workspace
    # Sandbox supplied to this Assembly, when present.
    attr_reader :sandbox

    def initialize(run: nil, runtime: nil, workspace: nil, sandbox: nil, standalone: run.nil?) # :nodoc:
      @run = run
      @runtime = runtime || run&.runtime || LittleGhost.runtime
      @workspace = workspace || (run.workspace if run&.respond_to?(:workspace))
      @sandbox = sandbox || (run.sandbox if run&.respond_to?(:sandbox))
      @standalone = standalone
      @assembly_mutex = Mutex.new
      @assembly_closed = false
      @active_assemblies = []
    end

    # Builds the top-level Run used by a standalone assembly.
    def build_run(payload) # :nodoc:
      payload = payload.dup if payload.is_a?(Hash)
      cancellation_token = if payload.is_a?(Hash)
        payload.delete(:cancellation_token) || payload.delete("cancellation_token")
      end
      source_class = self.class.respond_to?(:assembly_source_class) ? self.class.assembly_source_class : self.class
      options = {entrypoint_class: source_class}
      options[:execution_class] = self.class unless source_class.equal?(self.class)
      options[:agent_class] = source_class if is_a?(Agent)
      options[:cancellation_token] = cancellation_token if cancellation_token
      options[:workspace] = workspace if workspace
      options[:sandbox] = sandbox if sandbox
      runtime.build_run(payload, **options)
    end

    # Starts +payload+ on a supervised worker and returns an Execution.
    def start_execution(payload, &event_consumer)
      ensure_standalone!
      Execution.start(build_run(payload), &event_consumer)
    end

    # Runs +input+ to completion.
    #
    # A standalone assembly returns a Run. A run-scoped assembly returns its
    # RunResult.
    def call(input = nil, **options)
      return build_run(entrypoint_payload(input, options)).call if standalone?

      result = nil
      stream(input, **options).each do |event|
        result = event.data[:result] if event.type == :invocation_stop
      end
      result
    end

    # Runs +message+ to completion.
    #
    # A standalone instance returns its owning Run. A run-scoped instance
    # returns the child RunResult.
    def ask(message, **options)
      call(message, **options)
    end

    # Lazily streams +message+ through the standalone or run-scoped assembly.
    #
    # A standalone stream returns its terminal Run after enumeration. A
    # run-scoped stream finishes with an +invocation_stop+ event containing its
    # RunResult.
    def stream_ask(message, **options)
      if standalone?
        options[:deadline_at] = options.delete(:deadline) if options.key?(:deadline)
        stream = nil
        return Enumerator.new do |events|
          stream ||= build_run(entrypoint_payload(message, options)).each
          stream.each { |event| events << event }
        end
      end

      stream(message, **options)
    end

    # Exposes this assembly as a Tool instance.
    #
    # By default, calls do not remember earlier conversation history. Set
    # <tt>preserve_context: true</tt> to carry that history from one tool call to
    # the next. This option does not control working state: every call receives
    # the invoking Tool's current RunContext#state, which may include current
    # request values or values restored from a Session. Nested tools must still
    # authorize privileged work with current, application-established values.
    def as_tool(name: self.class.assembly_id, description: self.class.description, preserve_context: false)
      assembly = self
      description = "Delegate a task to #{name}." if description.to_s.empty?
      mutex = Mutex.new
      retained_history = []
      tool_class = Tool.define(
        name:,
        description:,
        input_schema: {
          type: "object",
          properties: {input: {type: "string"}},
          required: ["input"],
          additionalProperties: false
        }
      ) do |input, context: nil|
        invocation = lambda do
          target = if assembly.is_a?(Agent)
            assembly
          elsif assembly.run
            assembly.runtime.build_assembly(assembly.class, run: assembly.run)
          else
            assembly.class.new(runtime: assembly.runtime)
          end
          options = {
            history: preserve_context ? retained_history : [],
            context: context&.state || {},
            cancellation_token: context&.cancellation_token || Support::CancellationToken.new,
            deadline: context&.deadline,
            parent_operation_id: assembly.run&.operation_id
          }
          if target.is_a?(Agent)
            options[:interruption_metadata] = context&.interruption_metadata
            options[:interruption_ids] = context&.interruption_ids || []
          end
          result = target.call(input.fetch("input"), **options)
          if result.is_a?(Run)
            raise result.error if result.error

            result = result.result
          end
          raise ProtocolError, "assembly tool invocation did not return a result" unless result

          retained_history.replace(result.messages.reject { |message| message.role == :system }) if preserve_context
          result.structured? ? result.structured_result.value : result.text
        ensure
          target&.close unless target.equal?(assembly)
        end
        preserve_context ? mutex.synchronize(&invocation) : invocation.call
      end
      tool_class.define_method(:close) { assembly.close }
      tool_class.new(binding: Tool::Binding.new(
        agent: (self if is_a?(Agent)),
        run:,
        runtime:,
        model: (model if respond_to?(:model)),
        workspace:,
        sandbox:
      ))
    end

    # Adds +message+ to the single active leaf Agent and returns its text reply.
    def interrupt(message, **options)
      interrupt_response(message, **options).text
    end

    # Adds an interruption to the single active leaf Agent.
    def interrupt_response(message, **options)
      child = @assembly_mutex.synchronize do
        active = @active_assemblies.dup
        if active.empty?
          raise AgentInterruptError, "Assembly is not currently running"
        end
        if active.length > 1
          raise AgentInterruptError, "Assembly has multiple active participants; the interruption target is ambiguous"
        end
        active.first
      end
      child.interrupt_response(message, **options)
    end

    # Closes resources owned directly by this assembly.
    def close
      @assembly_mutex.synchronize do
        return if @assembly_closed

        @assembly_closed = true
      end
    end

    def entrypoint_name = self.class.assembly_id # :nodoc:

    # Additional prompt locals made available to child agents.
    def prompt_locals = {}

    protected

    def standalone? = @standalone # :nodoc:

    def with_active_assembly(assembly) # :nodoc:
      @assembly_mutex.synchronize do
        raise Error, "assembly is already closed" if @assembly_closed
        @active_assemblies << assembly
      end
      yield
    ensure
      @assembly_mutex.synchronize { @active_assemblies.delete(assembly) } if assembly
    end

    def entrypoint_payload(input, options) # :nodoc:
      return options if input.nil?
      return input.merge(options) if input.is_a?(Hash)

      {message: input, **options}
    end

    private

    def ensure_standalone!
      raise Error, "Only a standalone assembly can start an execution" unless standalone?
    end
  end
end
