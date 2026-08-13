# frozen_string_literal: true

module LittleGhost
  # An immutable, executable snapshot produced by an AssemblyBuilder.
  AssemblyDefinition = Data.define(:kind, :assembly_id, :description, :implementation) do
    def initialize(kind:, assembly_id:, description:, implementation:)
      super(
        kind: kind.to_sym,
        assembly_id: assembly_id.to_s.dup.freeze,
        description: description.to_s.dup.freeze,
        implementation:
      )
    end
  end

  # Builds an Assembly when its participants or routes are discovered at runtime.
  #
  # Class definitions are the usual, easier-to-find way to declare behavior.
  # Builders expose the underlying dynamic form while preserving the same
  # +ask+, +stream_ask+, +call+, and +stream+ interface:
  #
  #   graph = LittleGhost::GraphBuilder.new(id: "support_flow")
  #   graph.node :triage, TriageAgent
  #   graph.node :respond, CustomerSupportAgent
  #   graph.start :triage
  #   graph.edge :triage, :respond
  #   graph.finish :respond
  #   graph.validate!
  #
  #   run = graph.ask("Can I get a refund?")
  #
  # A builder remains mutable. Each build or invocation snapshots declaration
  # containers and referenced Assembly definitions, so later builder changes
  # affect only future executions. Executable Ruby closures and the external
  # objects they reference remain live trusted application code.
  class AssemblyBuilder
    # Optional Runtime reused by standalone executions from this builder.
    attr_reader :runtime

    # Creates a mutable builder with optional identity, runtime, and base class.
    def initialize(id: nil, description: nil, runtime: nil, base: nil)
      @mutex = Mutex.new
      @assembly_id = id&.to_s&.dup&.freeze
      @description = description&.to_s&.dup&.freeze
      @runtime = runtime
      @base = base
    end

    # Reads or assigns the stable Assembly identifier.
    def assembly_id(value = nil)
      return @mutex.synchronize { @assembly_id || default_assembly_id } if value.nil?

      @mutex.synchronize { @assembly_id = String(value).dup.freeze }
      self
    end

    # Reads or assigns the human-readable description.
    def description(value = nil)
      return @mutex.synchronize { @description || base_description } if value.nil?

      @mutex.synchronize { @description = String(value).dup.freeze }
      self
    end

    # Returns +:agent+, +:workflow+, +:swarm+, or +:graph+.
    def assembly_kind = self.class.assembly_kind

    # Validates the current snapshot and returns this mutable builder.
    def validate!
      definition
      self
    end

    # Returns an immutable, recursively snapshotted definition.
    def definition
      stack = Thread.current[:little_ghost_assembly_definition_stack] ||= []
      identity = base || self
      if stack.include?(identity)
        raise ConfigurationError, "assembly definitions cannot contain themselves recursively"
      end
      stack << identity
      state = @mutex.synchronize { snapshot_state }
      implementation = build_implementation(state)
      prepare_implementation!(implementation)
      validate_implementation!(implementation)
      seal_implementation!(implementation)
      implementation.freeze
      AssemblyDefinition.new(
        kind: assembly_kind,
        assembly_id: implementation.assembly_id,
        description: implementation.description,
        implementation:
      )
    ensure
      stack&.pop if stack&.last.equal?(identity)
      Thread.current[:little_ghost_assembly_definition_stack] = nil if stack && stack.empty?
    end

    # Builds one execution instance from the current definition snapshot.
    def build(runtime: self.runtime, run: nil)
      snapshot = definition
      return (runtime || run.runtime).build_assembly(snapshot, run:) if run

      snapshot.implementation.new(runtime:)
    end

    # Executes a standalone snapshot and returns its Run.
    def ask(message, **options) = build.ask(message, **options)

    # Lazily streams a standalone snapshot.
    def stream_ask(message, **options)
      snapshot = definition
      Enumerator.new do |events|
        snapshot.implementation.new(runtime:).stream_ask(message, **options).each { |event| events << event }
      end
    end

    # Executes a snapshot to completion.
    def call(input = nil, **options) = build.call(input, **options)
    # Streams a snapshot as StreamEvent objects.
    def stream(input = nil, **options) = build.stream(input, **options)
    # Starts a supervised execution from a snapshot.
    def start_execution(payload, &block) = build.start_execution(payload, &block)
    # Exposes a snapshot as a Tool.
    def as_tool(**options) = build.as_tool(**options)

    protected

    attr_reader :base

    def snapshot_state
      {
        assembly_id: @assembly_id || default_assembly_id,
        description: @description || base_description,
        base:
      }
    end

    def configure_implementation(implementation, state)
      implementation.assembly_id(state.fetch(:assembly_id))
      implementation.description(state.fetch(:description))
      implementation
    end

    def validate_implementation!(_implementation) = nil

    def prepare_implementation!(_implementation) = nil

    def snapshot_mutators = %i[assembly_id description]

    def seal_implementation!(implementation)
      mutators = snapshot_mutators + implementation.singleton_methods.grep(/=\z/)
      implementation.instance_variables.each do |name|
        value = implementation.instance_variable_get(name)
        implementation.instance_variable_set(name, deep_freeze_snapshot_value(value))
      end
      implementation.methods.grep(/_value\z/).each do |reader|
        writer = :"#{reader}="
        next unless implementation.respond_to?(writer)

        implementation.public_send(writer, deep_freeze_snapshot_value(implementation.public_send(reader)))
        mutators << writer
      end
      mutators.uniq.each do |name|
        implementation.define_singleton_method(name) do |*arguments, **keywords, &block|
          if !name.to_s.end_with?("=") && arguments.empty? && keywords.empty? && !block
            super()
          else
            raise FrozenError, "can't modify immutable Assembly definition"
          end
        end
      end
    end

    def deep_freeze_snapshot_value(value)
      case value
      when Hash
        value.each do |key, child|
          deep_freeze_snapshot_value(key)
          deep_freeze_snapshot_value(child)
        end
        value.freeze
      when Array
        value.each { |child| deep_freeze_snapshot_value(child) }
        value.freeze
      when String
        value.freeze
      when Data
        value.members.each { |member| deep_freeze_snapshot_value(value.public_send(member)) }
        value.freeze
      else
        value
      end
    end

    def snapshot_reference(value)
      return value.definition if value.is_a?(AssemblyBuilder)
      return value.definition if value.is_a?(Class) && value <= Assembly

      value
    end

    def snapshot_base_class(value)
      return unless value

      snapshot = value.dup
      source_name = value.name
      snapshot.define_singleton_method(:name) { source_name } if source_name
      snapshot.define_singleton_method(:assembly_source_class) { value }
      value.instance_variables.each do |name|
        snapshot.instance_variable_set(name, Support.deep_dup(value.instance_variable_get(name)))
      end
      value.methods.grep(/_value\z/).each do |reader|
        writer = :"#{reader}="
        next unless snapshot.respond_to?(writer)

        snapshot.public_send(writer, Support.deep_dup(value.public_send(reader)))
      end
      snapshot.assembly_id(value.assembly_id)
      snapshot.description(value.description)
      if value <= Agent
        path = value.logical_path
        snapshot.define_singleton_method(:logical_path) { path }
      end
      snapshot
    end

    def base_description = base&.description.to_s
    def default_assembly_id = base&.assembly_id || assembly_kind.to_s
  end

  # Builds an Agent definition from declarations made at runtime.
  # Supported Agent class-DSL calls are recorded and replayed into each
  # immutable snapshot.
  class AgentBuilder < AssemblyBuilder
    DECLARATIONS = %i[
      model limits result_schema capture_diagnostics system_template system_prompt
      tools prompt_local after_initialize before_invocation after_invocation
      before_model after_model after_model_error before_tool after_tool
      manage_context detect_tool_loops skills subagent subagents
      subagent_long_poll_duration agent_as_tool agents_as_tools
      assembly_as_tool assemblies_as_tools
    ].freeze # :nodoc:

    class << self
      # :nodoc:
      def assembly_kind = :agent
    end

    # Creates a mutable dynamic Agent definition.
    def initialize(**options)
      super
      @operations = []
    end

    # Reads or assigns the Agent identifier.
    def agent_id(value = nil)
      value.nil? ? assembly_id : assembly_id(value)
    end

    # Records supported Agent class-DSL declarations for the next snapshot.
    def method_missing(name, *arguments, **keywords, &block)
      return super unless DECLARATIONS.include?(name)

      @mutex.synchronize { @operations << [name, arguments, keywords, block] }
      self
    end

    # Reports the declarative methods supported by Agent.
    def respond_to_missing?(name, include_private = false)
      DECLARATIONS.include?(name) || super
    end

    protected

    def snapshot_mutators = super + [:agent_id, *DECLARATIONS]

    def snapshot_state
      operations = @operations.map do |name, arguments, keywords, block|
        [name, Support.deep_dup(arguments).freeze, Support.deep_dup(keywords).freeze, block].freeze
      end
      super.merge(operations: operations.freeze)
    end

    def build_implementation(state)
      implementation = snapshot_base_class(state.fetch(:base)) || Class.new(Agent)
      configure_implementation(implementation, state)
      state.fetch(:operations).each do |name, arguments, keywords, block|
        if keywords.empty?
          implementation.public_send(name, *arguments, &block)
        else
          implementation.public_send(name, *arguments, **keywords, &block)
        end
      end
      implementation
    end

    def prepare_implementation!(implementation)
      declarations = implementation.assembly_tool_declarations.map do |declaration|
        declaration.merge(assembly: snapshot_reference(declaration.fetch(:assembly))).freeze
      end
      implementation.assembly_tool_declarations_value = declarations.freeze
      subagents = implementation.subagent_declarations.map do |declaration|
        declaration.merge(agent: snapshot_reference(declaration.fetch(:agent))).freeze
      end
      implementation.subagent_declarations_value = subagents.freeze
    end
  end

  # Builds a Workflow whose Ruby composition block is supplied at runtime.
  class WorkflowBuilder < AssemblyBuilder
    class << self
      # :nodoc:
      def assembly_kind = :workflow
    end

    # Declares the Ruby composition body for dynamic Workflow executions.
    def perform(&block)
      raise ArgumentError, "perform requires a block" unless block

      @mutex.synchronize { @performer = block }
      self
    end

    protected

    def snapshot_mutators = super + [:perform]

    def snapshot_state = super.merge(performer: @performer)

    def build_implementation(state)
      implementation = snapshot_base_class(state.fetch(:base)) || Class.new(Workflow)
      configure_implementation(implementation, state)
      if (performer = state.fetch(:performer))
        implementation.define_method(:perform) { performer.call(self) }
        implementation.send(:private, :perform)
      end
      implementation
    end

    def validate_implementation!(_implementation)
      raise ConfigurationError, "workflow builder must declare perform" unless @performer || base
    end
  end

  # Builds a Swarm at runtime while keeping its members Agent-only.
  class SwarmBuilder < AssemblyBuilder
    class << self
      # :nodoc:
      def assembly_kind = :swarm
    end

    # Creates a mutable dynamic Swarm definition.
    def initialize(**options)
      super
      @declarations = []
    end

    %i[member start max_steps handoff max_handoff_repeats].each do |name|
      define_method(name) do |*arguments, **keywords, &block|
        @mutex.synchronize { @declarations << [name, arguments, keywords, block] }
        self
      end
    end

    protected

    def snapshot_mutators = super + %i[member start max_steps handoff max_handoff_repeats]

    def snapshot_state = super.merge(declarations: @declarations.map { |value| value.dup.freeze }.freeze)

    def build_implementation(state)
      implementation = snapshot_base_class(state.fetch(:base)) || Class.new(Swarm)
      configure_implementation(implementation, state)
      replay(implementation, state.fetch(:declarations))
    end

    def validate_implementation!(implementation) = implementation.swarm_definition!

    def prepare_implementation!(implementation)
      members = implementation.swarm_members_value.to_h do |id, member|
        copied = Support.deep_dup(member.to_h)
        [id, Swarm::Member.new(**copied.merge(agent: snapshot_reference(member.agent)))]
      end
      implementation.swarm_members_value = members.freeze
    end

    private

    def replay(implementation, declarations)
      declarations.each do |name, arguments, keywords, block|
        arguments = arguments.map { |value| snapshot_reference(value) }
        implementation.public_send(name, *arguments, **keywords, &block)
      end
      implementation
    end

    def snapshot_reference(value)
      if value.is_a?(AssemblyBuilder) && !value.is_a?(AgentBuilder)
        raise ConfigurationError, "swarm members must be Agent definitions"
      end
      if value.is_a?(AssemblyDefinition) && value.kind != :agent
        raise ConfigurationError, "swarm members must be Agent definitions"
      end

      super
    end
  end

  # Builds a Graph from nodes and routes discovered at runtime.
  class GraphBuilder < AssemblyBuilder
    class << self
      # :nodoc:
      def assembly_kind = :graph
    end

    # Creates a mutable dynamic Graph definition.
    def initialize(**options)
      super
      @declarations = []
    end

    %i[node start edge finish max_steps fork join error_edge].each do |name|
      define_method(name) do |*arguments, **keywords, &block|
        @mutex.synchronize { @declarations << [name, arguments, keywords, block] }
        self
      end
    end

    # Renders the current validated snapshot as Mermaid flowchart text.
    def to_mermaid = definition.implementation.to_mermaid

    protected

    def snapshot_mutators = super + %i[node start edge finish max_steps fork join error_edge]

    def snapshot_state = super.merge(declarations: @declarations.map { |value| value.dup.freeze }.freeze)

    def build_implementation(state)
      implementation = snapshot_base_class(state.fetch(:base)) || Class.new(Graph)
      configure_implementation(implementation, state)
      state.fetch(:declarations).each do |name, arguments, keywords, block|
        arguments = arguments.map { |value| value.is_a?(AssemblyBuilder) ? value.definition : value }
        implementation.public_send(name, *arguments, **keywords, &block)
      end
      implementation
    end

    def validate_implementation!(implementation) = implementation.validate!

    def prepare_implementation!(implementation)
      nodes = implementation.graph_nodes_value.to_h do |id, node|
        copied = Support.deep_dup(node.to_h)
        [id, Graph::Node.new(**copied.merge(assembly: snapshot_reference(node.assembly)))]
      end
      implementation.graph_nodes_value = nodes.freeze
    end
  end
end
