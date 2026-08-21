# frozen_string_literal: true

require "json"
require_relative "assembly"

module LittleGhost
  # Routes a request through named Assembly nodes and declared edges.
  #
  # A Graph is an Assembly for flows whose allowed paths should be visible in
  # application code. A node may contain an Agent, Workflow, Swarm, or another
  # Graph. Edges declare which node may run next.
  #
  #   class SupportFlowGraph < LittleGhost::Graph
  #     node :triage, TriageAgent
  #     node :ledger, LedgerResearchAgent
  #     node :policy, PolicyResearchAgent
  #     node :respond, CustomerSupportAgent
  #
  #     start :triage
  #     edge :triage, :ledger
  #     edge :triage, :policy
  #     edge :ledger, :respond
  #     edge :policy, :respond
  #     finish :respond
  #   end
  #
  #   SupportFlowGraph.validate!
  #   run = SupportFlowGraph.ask("Why is my transfer pending?")
  #
  # Call a named Graph with ask[rdoc-ref:LittleGhost::Assembly.ask] for its final
  # Run, or the streaming entrypoint[rdoc-ref:LittleGhost::Assembly.stream_ask]
  # for routing and final-response events.
  #
  # Multiple unconditional edges from one source run in parallel and converge
  # at their first unambiguous common successor. Array endpoints declare an
  # explicit fan-out or wait-for-all fan-in. Parallel groups cannot nest.
  # Conditions and input mappers receive a read-only Graph::State. Nodes do not
  # receive caller history or application context unless their declaration
  # opts in with <tt>history: true</tt> or <tt>context: true</tt>. Validate the
  # topology before execution. Conditions and mappers are application callbacks
  # and can inspect copied input, history, context, and completed results. +to_mermaid+
  # renders the same definition as a flowchart.
  class Graph < Assembly
    Node = Data.define(:name, :assembly, :policies, :inherit_history, :inherit_context, :input_mapper) # :nodoc:
    Edge = Data.define(:from, :to, :condition, :input_mapper, :max_concurrency) # :nodoc:
    ErrorEdge = Data.define(:from, :to, :errors, :input_mapper) # :nodoc:
    Fork = Data.define(:from, :to, :condition, :max_concurrency, :input_mappers) # :nodoc:
    Join = Data.define(:from, :to, :input_mapper, :fork) # :nodoc:
    BranchResult = Data.define(:terminal, :results, :steps, :usage, :events) # :nodoc:
    EventSink = Data.define(:consumer) do # :nodoc:
      def <<(event)
        consumer.call(event)
        self
      end
    end

    # Read-only routing data passed to conditions and input mappers.
    #
    # +results+ contains every completed node result. +incoming_results+
    # contains only the immediate predecessors supplying the current node.
    # +previous+ and #previous_result are present for a single predecessor;
    # +predecessors+ preserves declaration order for fan-in execution.
    class State
      # A copied Message containing the original request.
      attr_reader :input
      # A frozen copy of caller history available to the condition or mapper.
      attr_reader :history
      # A frozen copy of application context available to the condition or mapper.
      attr_reader :context
      # The one-based execution count assigned to the current node.
      attr_reader :step
      # The source node for a condition, or destination node for an input mapper.
      attr_reader :current
      # The predecessor name when exactly one result supplies the current node.
      attr_reader :previous
      # The immediate predecessor names in declaration order.
      attr_reader :predecessors
      # Frozen copies of completed RunResults keyed by node name.
      attr_reader :results
      # Frozen copies of immediate predecessor RunResults keyed by node name.
      attr_reader :incoming_results
      # A frozen copy of the routed exception available to an error-edge mapper.
      attr_reader :error

      def initialize(input:, history:, context:, step:, current:, previous:, results:,
        predecessors: [], incoming_results: {}, error: nil) # :nodoc:
        @input = input
        @history = history
        @context = context
        @step = step
        @current = current
        @previous = previous
        @predecessors = Array(predecessors).map(&:to_sym).freeze
        @results = results.dup.freeze
        @incoming_results = incoming_results.dup.freeze
        @error = error
        freeze
      end

      # Returns a completed result by node name.
      def result(node_name) = results[node_name.to_sym]
      # Returns the immediately preceding result when present.
      def previous_result = previous && result(previous)
    end

    extend Support::ClassAttributes

    class_attribute :graph_nodes_value, default: {}.freeze
    class_attribute :graph_edges_value, default: [].freeze
    class_attribute :graph_error_edges_value, default: [].freeze
    class_attribute :graph_start_value
    class_attribute :graph_finish_value
    class_attribute :graph_max_steps_value, default: 20
    class_attribute :graph_max_concurrency_value, default: 8

    class << self
      # Declares an Assembly node and its optional execution policy.
      #
      # An +input+ mapper receives Graph::State and replaces the default input
      # whenever the selected edge or edge group does not declare its own
      # mapper. +history+ and +context+ opt this node into the corresponding
      # caller data; both default to +false+.
      def node(name, assembly, timeout: nil, retries: 0, retry_on: nil, retry_delay: 0,
        history: false, context: false, input: nil)
        name = normalize_node_name(name)
        raise ConfigurationError, "graph node #{name.inspect} is already declared" if graph_nodes_value.key?(name)
        unless [history, context].all? { |value| value == true || value == false }
          raise ArgumentError, "graph node history and context options must be true or false"
        end
        validate_callable!(input, "node input mapper")

        policies = {timeout:, retries:, retry_on:, retry_delay:}.freeze
        declaration = Node.new(
          name:, assembly:, policies:,
          inherit_history: history,
          inherit_context: context,
          input_mapper: input
        )
        self.graph_nodes_value = graph_nodes_value.merge(name => declaration).freeze
      end

      # Reads or assigns the entry node.
      def start(name = nil)
        return graph_start_value if name.nil?

        self.graph_start_value = normalize_node_name(name)
      end

      # Declares one route or one bounded parallel edge group.
      #
      # +input+ receives Graph::State and returns the value passed to the target
      # node or nodes. A scalar source and Array target fan out; an Array source
      # and scalar target wait for every listed predecessor. At most one
      # conditional scalar or grouped route may match from the current node;
      # one unconditional route may act as the fallback. Multiple unconditional
      # scalar edges with the same source infer one fan-out when no conditional
      # route is present. Supply a condition with +if:+ or a block.
      #
      # +max_concurrency+ overrides Graph.max_concurrency for a scalar-to-Array
      # fan-out. The original request and complete source output cross to every
      # branch unless an input mapper replaces them. Array-to-Array edges,
      # conditional fan-in edges, and +max_concurrency+ on other edge shapes
      # raise ArgumentError.
      def edge(from, to, input: nil, max_concurrency: nil, **options, &condition)
        condition = extract_condition(options, condition)
        validate_callable!(input, "edge input mapper")
        from = normalize_endpoint(from, "edge source")
        to = normalize_endpoint(to, "edge target")
        if from.is_a?(Array) && to.is_a?(Array)
          raise ArgumentError, "graph edges cannot use arrays for both source and target"
        end
        if from.is_a?(Array) && condition
          raise ArgumentError, "fan-in edges cannot be conditional"
        end
        unless max_concurrency.nil?
          raise ArgumentError, "max_concurrency is only valid for a fan-out edge" unless to.is_a?(Array)

          max_concurrency = normalize_max_concurrency(max_concurrency)
        end
        declaration = Edge.new(
          from:,
          to:,
          condition:,
          input_mapper: input,
          max_concurrency:
        )
        self.graph_edges_value = (graph_edges_value + [declaration]).freeze
        declaration
      end

      # Routes selected node errors after retries are exhausted.
      #
      # +on+ lists the exception classes this route accepts. An +input+ mapper
      # may turn Graph::State, including +state.error+, into recovery input.
      def error_edge(from, to, on:, input: nil)
        errors = Array(on)
        unless errors.any? && errors.all? { |error| error.is_a?(Class) && error <= Exception }
          raise ArgumentError, "error edge on: must contain exception classes"
        end
        validate_callable!(input, "error edge input mapper")
        declaration = ErrorEdge.new(
          from: normalize_node_name(from),
          to: normalize_node_name(to),
          errors: errors.freeze,
          input_mapper: input
        )
        self.graph_error_edges_value = (graph_error_edges_value + [declaration]).freeze
        declaration
      end

      # Reads or assigns the terminal node.
      def finish(name = nil)
        return graph_finish_value if name.nil?

        self.graph_finish_value = normalize_node_name(name)
      end

      # Reads or assigns the maximum node executions.
      def max_steps(value = nil)
        return graph_max_steps_value if value.nil?

        value = Integer(value)
        raise ArgumentError, "max_steps must be at least 1" if value < 1

        self.graph_max_steps_value = value
      end

      # Reads or assigns the concurrency bound for parallel groups.
      #
      # The default is 8. A scalar-to-Array edge may override it for one group.
      def max_concurrency(value = nil)
        return graph_max_concurrency_value if value.nil?

        self.graph_max_concurrency_value = normalize_max_concurrency(value)
      end

      # Validates the topology and returns this Graph class.
      #
      # Raises ConfigurationError for undeclared or unreachable nodes,
      # ambiguous convergence, competing routes at an inferred branch
      # boundary, and overlapping or nested parallel groups.
      def validate!
        graph_definition!
        self
      end

      def graph_definition! # :nodoc:
        nodes = graph_nodes_value
        start_name = graph_start_value
        finish_name = graph_finish_value
        raise ConfigurationError, "graph must declare at least one node" if nodes.empty?
        raise ConfigurationError, "graph must declare a start node" unless start_name
        raise ConfigurationError, "graph must declare a finish node" unless finish_name
        validate_declared_node!(nodes, start_name, "start")
        validate_declared_node!(nodes, finish_name, "finish")
        nodes.each_value { |node| validate_step_policy!(node.policies) }

        graph_edges_value.each do |declaration|
          Array(declaration.from).each { |name| validate_declared_node!(nodes, name, "edge source") }
          Array(declaration.to).each { |name| validate_declared_node!(nodes, name, "edge target") }
          if Array(declaration.from).include?(finish_name)
            raise ConfigurationError, "graph finish node #{finish_name.inspect} cannot have outgoing edges"
          end
        end
        graph_error_edges_value.each do |declaration|
          validate_declared_node!(nodes, declaration.from, "error edge source")
          validate_declared_node!(nodes, declaration.to, "error edge target")
        end
        edges, forks, joins = compile_edges
        validate_routes!(edges, forks)
        validate_parallel_structure!(edges, forks, joins)
        validate_success_routes!(nodes, finish_name, edges, forks, joins)
        validate_reachability!(nodes, start_name, finish_name, edges, forks, joins)
        [
          nodes, edges.freeze, graph_error_edges_value,
          forks.freeze, joins.freeze, start_name, finish_name
        ]
      end

      # Renders the validated topology as Mermaid flowchart text.
      def to_mermaid
        nodes, edges, error_edges, forks, joins, start_name, finish_name = graph_definition!
        lines = ["flowchart TD"]
        nodes.each_key { |name| lines << "  #{mermaid_id(name)}[#{name}]" }
        lines << "  START((start)) --> #{mermaid_id(start_name)}"
        lines << "  #{mermaid_id(finish_name)} --> FINISH((finish))"
        fan_in_pairs = joins.flat_map { |join| join.from.map { |source| [source, join.to] } }.to_set
        edges.each do |edge|
          next if fan_in_pairs.include?([edge.from, edge.to])

          label = edge.condition ? "condition" : nil
          lines << mermaid_edge(edge.from, edge.to, label:)
        end
        error_edges.each { |edge| lines << mermaid_edge(edge.from, edge.to, label: "error", dotted: true) }
        forks.each do |fork|
          fork.to.each { |target| lines << mermaid_edge(fork.from, target, label: "fork") }
        end
        joins.each do |join|
          join.from.each { |source| lines << mermaid_edge(source, join.to, label: "join") }
        end
        lines.join("\n")
      end

      private

      def compile_edges
        scalar_edges = []
        forks = []
        explicit_joins = []
        graph_edges_value.each do |edge|
          if edge.to.is_a?(Array)
            input_mappers = edge.to.to_h { |target| [target, edge.input_mapper] }.freeze
            forks << Fork.new(
              from: edge.from, to: edge.to, condition: edge.condition,
              max_concurrency: edge.max_concurrency || graph_max_concurrency_value,
              input_mappers:
            )
          elsif edge.from.is_a?(Array)
            explicit_joins << Join.new(from: edge.from, to: edge.to, input_mapper: edge.input_mapper, fork: nil)
          else
            scalar_edges << edge
          end
        end

        inferred_edges = []
        scalar_edges.group_by(&:from).each do |source, candidates|
          unconditional = candidates.reject(&:condition)
          next unless unconditional.length > 1

          if candidates.any?(&:condition)
            raise ConfigurationError,
              "graph node #{source.inspect} cannot mix conditional routes with inferred fan-out edges"
          end
          targets = unconditional.map(&:to)
          raise ConfigurationError, "graph fan-out targets from #{source.inspect} must be unique" unless targets.uniq == targets

          forks << Fork.new(
            from: source, to: targets.freeze, condition: nil,
            max_concurrency: graph_max_concurrency_value,
            input_mappers: unconditional.to_h { |edge| [edge.to, edge.input_mapper] }.freeze
          )
          inferred_edges.concat(unconditional)
        end
        scalar_edges -= inferred_edges

        used_explicit_joins = []
        joins = forks.map do |fork|
          matches = explicit_joins.select { |join| join_matches_fork?(join, fork, scalar_edges) }
          if matches.length > 1
            raise ConfigurationError,
              "graph fan-out at #{fork.from.inspect} has more than one matching fan-in"
          end

          if matches.one?
            join = matches.first
            used_explicit_joins << join
            Join.new(from: join.from, to: join.to, input_mapper: join.input_mapper, fork:)
          else
            join, = infer_join(fork, scalar_edges, forks)
            Join.new(from: join.from, to: join.to, input_mapper: nil, fork:)
          end
        end
        unused = explicit_joins - used_explicit_joins
        if unused.any?
          raise ConfigurationError,
            "graph fan-in to #{unused.first.to.inspect} has no matching fan-out"
        end

        [scalar_edges, forks, joins]
      end

      def infer_join(fork, edges, forks)
        adjacency = adjacency_for(edges)
        reachable_sets = fork.to.map { |target| reachable_nodes(target, adjacency) }
        common = reachable_sets.reduce { |left, right| left & right } || Set.new
        earliest = common.reject do |candidate|
          common.any? { |other| other != candidate && reachable?(other, candidate, adjacency) }
        end
        candidates = earliest.filter_map do |target|
          incoming = edges.select { |edge| edge.to == target }
          assignments = fork.to.map do |branch|
            incoming.select { |edge| reachable?(branch, edge.from, adjacency) }
          end
          next unless assignments.all?(&:one?)

          selected = assignments.flatten
          next unless selected.map(&:from).uniq.length == fork.to.length
          if selected.any?(&:condition)
            raise ConfigurationError,
              "graph inferred fan-in to #{target.inspect} cannot use conditional incoming edges; " \
              "route each branch before its fan-in predecessor"
          end
          alternate = selected.find do |edge|
            edges.any? { |candidate| candidate.from == edge.from && !candidate.equal?(edge) } ||
              forks.any? { |candidate| candidate.from == edge.from }
          end
          if alternate
            raise ConfigurationError,
              "graph cannot infer fan-in at #{alternate.from.inspect} because it has another successful route; " \
              "route the branch before that predecessor or declare an explicit array-source edge"
          end
          if selected.any?(&:input_mapper)
            raise ConfigurationError,
              "graph inferred fan-in to #{target.inspect} cannot use input mappers on its incoming scalar edges; " \
              "map the target node or declare an explicit array-source edge"
          end

          [Join.new(from: selected.map(&:from).freeze, to: target, input_mapper: nil, fork:), selected]
        end
        unless candidates.one?
          detail = candidates.empty? ? "no unambiguous fan-in" : "more than one possible fan-in"
          raise ConfigurationError,
            "graph fan-out at #{fork.from.inspect} has #{detail}; declare an explicit array-source edge"
        end

        candidates.first
      end

      def join_matches_fork?(join, fork, edges)
        adjacency = adjacency_for(edges)
        assignments = fork.to.map do |target|
          join.from.select { |source| reachable?(target, source, adjacency) }
        end
        assignments.all?(&:one?) && assignments.flatten.uniq.length == fork.to.length
      end

      def adjacency_for(edges)
        Hash.new { |hash, key| hash[key] = [] }.tap do |adjacency|
          edges.each { |edge| adjacency[edge.from] << edge.to }
          graph_error_edges_value.each { |edge| adjacency[edge.from] << edge.to }
        end
      end

      def extract_condition(options, block)
        if options.key?(:if)
          raise ArgumentError, "provide an edge condition with if: or a block, not both" if block

          block = options.delete(:if)
        end
        raise ArgumentError, "unknown edge options: #{options.keys.join(", ")}" unless options.empty?
        validate_callable!(block, "edge condition")
        block
      end

      def validate_callable!(value, label)
        raise ArgumentError, "#{label} must respond to call" if value && !value.respond_to?(:call)
      end

      def validate_declared_node!(nodes, name, label)
        raise ConfigurationError, "graph #{label} #{name.inspect} is not declared" unless nodes.key?(name)
      end

      def validate_routes!(edges, forks)
        (edges + forks).group_by(&:from).each do |source, candidates|
          fallback = candidates.reject(&:condition)
          if fallback.length > 1
            raise ConfigurationError, "graph node #{source.inspect} has more than one unconditional route"
          end
        end
      end

      def validate_parallel_structure!(edges, forks, joins)
        used = Set.new
        forks.each do |fork|
          overlap = fork.to.select { |target| used.include?(target) }
          raise ConfigurationError, "graph fan-out branches overlap at #{overlap.first.inspect}" if overlap.any?

          used.merge(fork.to)
        end
        validate_no_nested_forks!(edges, forks, joins)
      end

      def validate_no_nested_forks!(edges, forks, joins)
        adjacency = adjacency_for(edges)
        forks.each do |outer|
          join = joins.find { |candidate| candidate.fork == outer }
          outer.to.each do |target|
            reachable = reachable_nodes(target, adjacency, stop_at: join.from)
            nested = forks.find { |candidate| candidate != outer && reachable.include?(candidate.from) }
            if nested
              raise ConfigurationError, "graph fan-out #{nested.from.inspect} cannot be nested inside another parallel branch"
            end
          end
        end
      end

      def reachable_nodes(from, adjacency, stop_at: [])
        seen = Set.new
        queue = [from]
        until queue.empty?
          current = queue.shift
          next unless seen.add?(current)
          next if stop_at.include?(current)

          queue.concat(adjacency[current])
        end
        seen
      end

      def validate_success_routes!(nodes, finish_name, edges, forks, joins)
        nodes.each_key do |name|
          next if name == finish_name
          next if edges.any? { |edge| edge.from == name }
          next if forks.any? { |fork| fork.from == name }
          next if joins.any? { |join| join.from.include?(name) }

          raise ConfigurationError, "graph node #{name.inspect} has no successful outgoing route"
        end
      end

      def reachable?(from, to, adjacency)
        seen = Set.new
        queue = [from]
        until queue.empty?
          current = queue.shift
          next unless seen.add?(current)
          return true if current == to

          queue.concat(adjacency[current])
        end
        false
      end

      def validate_reachability!(nodes, start_name, finish_name, edges, forks, joins)
        adjacency = Hash.new { |hash, key| hash[key] = [] }
        edges.each { |edge| adjacency[edge.from] << edge.to }
        graph_error_edges_value.each { |edge| adjacency[edge.from] << edge.to }
        forks.each { |fork| adjacency[fork.from].concat(fork.to) }
        joins.each { |join| join.from.each { |source| adjacency[source] << join.to } }
        reachable = Set.new
        queue = [start_name]
        until queue.empty?
          current = queue.shift
          next unless reachable.add?(current)

          queue.concat(adjacency[current])
        end
        unreachable = nodes.keys.reject { |name| reachable.include?(name) }
        raise ConfigurationError, "graph has unreachable node #{unreachable.first.inspect}" if unreachable.any?
        raise ConfigurationError, "graph finish node #{finish_name.inspect} is unreachable" unless reachable.include?(finish_name)
      end

      def normalize_node_name(value)
        value = value.to_sym
        raise ArgumentError, "graph node name cannot be empty" if value.to_s.empty?

        value
      rescue NoMethodError
        raise ArgumentError, "graph node name must be a String or Symbol"
      end

      def normalize_endpoint(value, label)
        return normalize_node_name(value) unless value.is_a?(Array)

        names = value.map { |name| normalize_node_name(name) }
        raise ArgumentError, "#{label} array requires at least two nodes" if names.length < 2
        raise ArgumentError, "#{label} nodes must be unique" unless names.uniq == names

        names.freeze
      end

      def normalize_max_concurrency(value)
        value = Integer(value)
        raise ArgumentError, "max_concurrency must be at least 1" if value < 1

        value
      end

      def mermaid_id(name) = "n_#{name.to_s.gsub(/[^a-zA-Z0-9_]/, "_")}"

      def mermaid_edge(from, to, label: nil, dotted: false)
        connector = dotted ? "-.->" : "-->"
        annotation = label ? "|#{label}|" : ""
        "  #{mermaid_id(from)} #{connector}#{annotation} #{mermaid_id(to)}"
      end
    end

    def initialize(run: nil, runtime: nil) # :nodoc:
      super(run:, runtime:, standalone: run.nil?)
      @graph_mutex = Mutex.new
      @graph_started = false
      @graph_children = []
      @graph_execution_count = 0
    end

    # Streams lifecycle events and the finish node's ordinary response events.
    def stream(input = nil, history: nil, context: nil,
      cancellation_token: Support::CancellationToken.new, deadline: nil,
      settings: nil, template_locals: nil, template_paths: nil,
      parent_operation_id: nil, checkpoint: nil, **_options)
      raise ArgumentError, "input is required" if input.nil?
      if standalone?
        return build_run(entrypoint_payload(input, {
          history:, context:, settings:, template_paths:,
          deadline_at: deadline, cancellation_token:
        }.compact)).each
      end

      reserve_execution!
      original_input = input.is_a?(Message) ? input : Message.new(role: :user, content: input)
      original_history = normalize_history(history)
      original_context = frozen_state(context || {})
      settings ||= {}
      template_locals ||= {}
      template_paths ||= []

      usage = Usage.new
      error_emitted = false
      Enumerator.new do |events|
        definition = self.class.graph_definition!
        nodes, edges, error_edges, forks, joins, current, finish = definition
        results = {}
        steps = []
        previous = nil
        incoming_edge = nil
        join_context = nil
        routed_error = nil
        previous_step_id = nil

        loop do
          count = next_graph_step!(cancellation_token, deadline)
          state = routing_state(
            input: original_input, history: original_history, context: original_context,
            step: count, current:, previous:, results:,
            predecessors: join_context&.fetch(:predecessors, []),
            incoming_results: join_context&.fetch(:results, {}) || {},
            error: routed_error
          )
          node_input = if join_context
            join_input_for(state, join_context.fetch(:join), nodes.fetch(current))
          else
            node_input_for(state, incoming_edge, nodes.fetch(current))
          end
          terminal = current == finish
          begin
            execution = execute_graph_node(
              node: nodes.fetch(current), input: node_input, history: original_history,
              context: original_context, cancellation_token:, deadline:, settings:,
              template_locals:, template_paths:, parent_operation_id:,
              predecessor_ids: join_context&.fetch(:step_ids, []) || Array(previous_step_id),
              terminal:, events:
            )
          rescue => error
            route = select_error_edge(error_edges.select { |edge| edge.from == current }, error)
            raise unless route

            usage += step_error_usage(error)
            error.instance_variable_set(:@little_ghost_step_usage_accounted, true)
            failed = failed_step(
              error,
              nodes.fetch(current),
              current,
              predecessor_ids: Array(previous_step_id)
            )
            steps << failed
            previous_step_id = failed.id
            incoming_edge = Edge.new(
              from: current, to: route.to, condition: nil,
              input_mapper: route.input_mapper, max_concurrency: nil
            )
            events << transition_event(count, current, route.to, error: true)
            previous = current
            current = route.to
            join_context = nil
            routed_error = error
            next
          end

          results[current] = execution.result
          previous_step_id = execution.step.id
          usage += execution.step.usage
          steps.concat(execution.result.steps)
          if terminal
            final = copy_run_result(execution.result, usage:, steps: steps.freeze)
            execution.events.each do |event|
              event = StreamEvent.build(event.type, **event.data.merge(result: final)) if event.type == :invocation_stop
              error_emitted = true if event.type == :invocation_error
              events << event
            end
            break
          end

          state = routing_state(
            input: original_input, history: original_history, context: original_context,
            step: count, current:, previous:, results:
          )
          selected = select_edge(
            edges.select { |edge| edge.from == current } + forks.select { |fork| fork.from == current },
            state
          )
          if selected.is_a?(Fork)
            fork = selected
            join = joins.find { |candidate| candidate.fork == fork }
            events << StreamEvent.build(
              :assembly_fork,
              assembly_id: self.class.assembly_id,
              assembly_kind: :graph,
              from: current,
              branches: fork.to
            )
            branch_outputs = run_graph_branches(
              fork:, join:, nodes:, edges:, error_edges:,
              original_input:, original_history:, original_context:,
              results:, source_step_id: previous_step_id,
              cancellation_token:, deadline:, settings:,
              template_locals:, template_paths:, parent_operation_id:, events:
            )
            unless join.from.sort == branch_outputs.map(&:terminal).sort
              raise AssemblyRoutingError, "graph fan-out at #{current.inspect} did not reach its inferred fan-in"
            end

            branch_outputs.each do |branch|
              results.merge!(branch.results)
              steps.concat(branch.steps)
              usage += branch.usage
              branch.events.each { |event| events << event }
            end
            events << StreamEvent.build(
              :assembly_join,
              assembly_id: self.class.assembly_id,
              assembly_kind: :graph,
              from: join.from,
              to: join.to
            )
            previous = nil
            current = join.to
            incoming_edge = nil
            join_context = {
              join:,
              predecessors: join.from,
              step_ids: branch_outputs.map { |branch| branch.steps.last.id },
              results: join.from.to_h { |name| [name, results.fetch(name)] }
            }
            previous_step_id = nil
            next
          end

          events << transition_event(count, current, selected.to)
          previous = current
          current = selected.to
          incoming_edge = selected
          join_context = nil
          routed_error = nil
        end
      rescue => error
        usage += unaccounted_step_error_usage(error)
        unless error_emitted
          events << StreamEvent.build(:invocation_error, error:, usage:, metadata: {})
        end
        raise
      end
    end

    def close
      children = @graph_mutex.synchronize { @graph_children.reverse }
      first_error = nil
      children.each do |child|
        child.close
      rescue => error
        first_error ||= error
      end
      super
      raise first_error if first_error
    end

    private

    def execute_graph_node(node:, input:, history:, context:, cancellation_token:, deadline:,
      settings:, template_locals:, template_paths:, parent_operation_id:,
      predecessor_ids:, terminal:, events:, branch_id: nil)
      step_id = SecureRandom.uuid
      events << StreamEvent.build(
        :assembly_step_start,
        assembly_id: self.class.assembly_id,
        assembly_kind: :graph,
        participant: node.name,
        branch_id:,
        step_id:
      )
      execution = execute_assembly_step(
        reference: node.assembly,
        participant: node.name,
        input:,
        history: node.inherit_history ? history : [],
        context: node.inherit_context ? context : {},
        cancellation_token:, deadline:, settings:,
        template_locals:, template_paths:, parent_operation_id:,
        policies: node.policies,
        predecessor_ids:,
        branch_id:,
        checkpoint: nil,
        step_id:
      ) { |event| events << event }
      events << StreamEvent.build(
        :assembly_step_stop,
        assembly_id: self.class.assembly_id,
        assembly_kind: :graph,
        participant: node.name,
        step_id: execution.step.id,
        branch_id:,
        usage: execution.step.usage
      )
      execution
    end

    def run_graph_branches(fork:, join:, nodes:, edges:, error_edges:, original_input:,
      original_history:, original_context:, results:, source_step_id:, cancellation_token:,
      deadline:, settings:, template_locals:, template_paths:, parent_operation_id:, events:)
      token = cancellation_token.child
      queue = SizedQueue.new(1_000)
      worker = task_runner.spawn do
        completed = []
        results = Support::Executor.new(
          max_concurrency: fork.max_concurrency,
          task_runner:
        ).map(
          fork.to,
          cancellation_token: token,
          on_result: ->(_index, result) { completed << result }
        ) do |start|
          run_graph_branch(
            start:, source: fork.from, source_step_id:, join:, nodes:, edges:,
            error_edges:, original_input:,
            original_history:, original_context:, parent_results: results,
            cancellation_token: token, deadline:, settings:, template_locals:,
            template_paths:, parent_operation_id:,
            event_consumer: ->(event) { enqueue_assembly_event(queue, [:event, event], token) }
          )
        end
        enqueue_assembly_event(queue, [:done, results], token)
      rescue => error
        token.cancel
        partial_usage = completed.sum(Usage.new) { |result| result.usage }
        partial_usage += step_error_usage(error)
        error.instance_variable_set(:@little_ghost_step_usage, partial_usage)
        enqueue_assembly_terminal(queue, [:error, error])
      end
      loop do
        type, value = queue.pop
        events << value if type == :event
        raise value if type == :error
        break value if type == :done
      end
    ensure
      token&.cancel
      worker&.wait
    end

    def run_graph_branch(start:, source:, source_step_id:, join:, nodes:, edges:,
      error_edges:, original_input:, original_history:, original_context:, parent_results:,
      cancellation_token:, deadline:, settings:, template_locals:, template_paths:,
      parent_operation_id:, event_consumer:)
      current = start
      previous = source
      incoming_edge = Edge.new(
        from: source, to: start, condition: nil,
        input_mapper: join.fork.input_mappers.fetch(start), max_concurrency: nil
      )
      local_results = {}
      local_steps = []
      local_usage = Usage.new
      local_events = EventSink.new(event_consumer)
      join_sources = join.from.to_set
      terminal = nil
      previous_step_id = source_step_id
      routed_error = nil

      loop do
        step_number = next_graph_step!(cancellation_token, deadline)
        all_results = parent_results.merge(local_results)
        state = routing_state(
          input: original_input, history: original_history, context: original_context,
          step: step_number, current:, previous:, results: all_results, error: routed_error
        )
        begin
          execution = execute_graph_node(
            node: nodes.fetch(current), input: node_input_for(state, incoming_edge, nodes.fetch(current)),
            history: original_history, context: original_context, cancellation_token:,
            deadline:, settings:, template_locals:, template_paths:, parent_operation_id:,
            predecessor_ids: Array(previous_step_id),
            terminal: false, events: local_events, branch_id: start
          )
        rescue => error
          route = select_error_edge(error_edges.select { |edge| edge.from == current }, error)
          raise unless route

          local_usage += step_error_usage(error)
          error.instance_variable_set(:@little_ghost_step_usage_accounted, true)
          failed = failed_step(
            error,
            nodes.fetch(current),
            current,
            branch_id: start,
            predecessor_ids: Array(previous_step_id)
          )
          local_steps << failed
          previous_step_id = failed.id
          previous = current
          current = route.to
          incoming_edge = Edge.new(
            from: previous, to: current, condition: nil,
            input_mapper: route.input_mapper, max_concurrency: nil
          )
          routed_error = error
          next
        end
        local_results[current] = execution.result
        previous_step_id = execution.step.id
        local_steps.concat(execution.result.steps)
        local_usage += execution.step.usage
        terminal = current
        break if join_sources.include?(terminal)

        state = routing_state(
          input: original_input, history: original_history, context: original_context,
          step: step_number, current:, previous:, results: parent_results.merge(local_results)
        )
        selected = select_edge(edges.select { |edge| edge.from == current }, state)
        local_events << transition_event(step_number, current, selected.to, branch_id: start)
        previous = current
        current = selected.to
        incoming_edge = selected
        routed_error = nil
      end
      BranchResult.new(
        terminal:, results: local_results.freeze, steps: local_steps.freeze,
        usage: local_usage, events: [].freeze
      )
    rescue => error
      error.instance_variable_set(
        :@little_ghost_step_usage,
        local_usage + step_error_usage(error)
      )
      raise
    end

    def reserve_execution!
      @graph_mutex.synchronize do
        raise Error, "graph instances can only be streamed once" if @graph_started

        @graph_started = true
      end
    end

    def next_graph_step!(token, deadline)
      token.raise_if_cancelled!
      raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline

      @graph_mutex.synchronize do
        if @graph_execution_count >= self.class.max_steps
          raise AssemblyLimitError, "#{self.class} reached its max_steps limit of #{self.class.max_steps}"
        end

        @graph_execution_count += 1
      end
    end

    def node_input_for(state, incoming_edge, node)
      return incoming_edge.input_mapper.call(state) if incoming_edge&.input_mapper
      return node.input_mapper.call(state) if node.input_mapper
      return state.input unless state.previous

      result = state.previous_result
      if state.error && !result
        return contextual_input(state, {state.previous => "Failed with #{state.error.class.name}."})
      end
      contextual_input(state, {state.previous => result.output})
    end

    def join_input_for(state, join, node)
      return join.input_mapper.call(state) if join.input_mapper
      return node.input_mapper.call(state) if node.input_mapper

      contextual_input(
        state,
        join.from.to_h { |name| [name, state.incoming_results.fetch(name).output] }
      )
    end

    def contextual_input(state, values)
      content = [Content::Text.new(text: "Original Task:\n")]
      content.concat(state.input.content)
      content << Content::Text.new(text: "\n\nInputs from previous nodes:")
      values.each do |name, value|
        content << Content::Text.new(text: "\n\nFrom #{name}:\n#{output_text(value)}")
      end
      Message.new(role: :user, content:, metadata: state.input.metadata)
    end

    def output_text(output)
      output.is_a?(String) ? output : JSON.generate(output)
    rescue JSON::GeneratorError
      output.to_s
    end

    def select_edge(candidates, state)
      raise AssemblyRoutingError, "graph node #{state.current.inspect} has no outgoing edge" if candidates.empty?

      conditional = candidates.select { |edge| edge.condition&.call(state) }
      if conditional.length > 1
        raise AssemblyRoutingError, "graph node #{state.current.inspect} matched more than one conditional edge"
      end
      return conditional.first if conditional.one?

      fallback = candidates.reject(&:condition)
      if fallback.length > 1
        raise AssemblyRoutingError, "graph node #{state.current.inspect} has more than one unconditional edge"
      end
      return fallback.first if fallback.one?

      raise AssemblyRoutingError, "graph node #{state.current.inspect} did not match an outgoing edge"
    end

    def select_error_edge(candidates, error)
      return nil if error.is_a?(CancelledError) || error.is_a?(DeadlineExceededError) || error.is_a?(CleanupError)

      matches = candidates.select { |edge| edge.errors.any? { |type| error.is_a?(type) } }
      raise AssemblyRoutingError, "graph error matched more than one error edge" if matches.length > 1

      matches.first
    end

    def failed_step(error, node, participant, branch_id: nil, predecessor_ids: [])
      Step.new(
        id: error.instance_variable_get(:@little_ghost_step_id) || SecureRandom.uuid,
        participant:,
        assembly_id: error.instance_variable_get(:@little_ghost_step_assembly_id) || assembly_reference_id(node.assembly),
        assembly_kind: error.instance_variable_get(:@little_ghost_step_assembly_kind) || :assembly,
        branch_id:,
        predecessor_ids:,
        status: :failed,
        attempts: error.instance_variable_get(:@little_ghost_step_attempts) || [],
        usage: step_error_usage(error)
      )
    end

    def step_error_usage(error) = error.instance_variable_get(:@little_ghost_step_usage) || Usage.new

    def unaccounted_step_error_usage(error)
      return Usage.new if error.instance_variable_get(:@little_ghost_step_usage_accounted)

      step_error_usage(error)
    end

    def assembly_reference_id(reference)
      return reference.assembly_id if reference.respond_to?(:assembly_id)
      return reference.assembly_id if reference.is_a?(Class) && reference <= Assembly

      reference.to_s
    end

    def transition_event(step, from, to, error: false, branch_id: nil)
      StreamEvent.build(
        :assembly_transition,
        assembly_id: self.class.assembly_id,
        assembly_kind: :graph,
        step:, from:, to:, error:, branch_id:
      )
    end

    def normalize_history(value)
      return [].freeze if value.nil?

      Array(value).map { |message| Message.coerce(message) }.freeze
    end

    def frozen_state(value)
      value = isolated_assembly_state(value)
      deep_freeze_assembly_value(value)
    end

    def routing_state(input:, history:, context:, step:, current:, previous:, results:,
      predecessors: [], incoming_results: {}, error: nil)
      predecessors ||= []
      incoming_results ||= {}
      if previous && predecessors.empty?
        predecessors = [previous]
        incoming_results = {previous => results.fetch(previous)} if results.key?(previous)
      end
      immutable_results = results.to_h { |name, result| [name, AgentStreamSnapshot.copy(result)] }
      immutable_incoming = incoming_results.to_h { |name, result| [name, AgentStreamSnapshot.copy(result)] }
      State.new(
        input: AgentStreamSnapshot.message(input),
        history: AgentStreamSnapshot.copy(history),
        context: AgentStreamSnapshot.copy(context),
        step:, current:, previous:,
        predecessors:, results: immutable_results,
        incoming_results: immutable_incoming,
        error: error && AgentStreamSnapshot.copy(error)
      )
    end
  end
end
