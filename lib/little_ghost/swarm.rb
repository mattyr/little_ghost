# frozen_string_literal: true

require "json"
require_relative "assembly"

module LittleGhost
  # Lets configured Agent members hand one request directly to one another.
  #
  # A swarm is an Assembly for model-selected routing. One member is active at a
  # time. It either produces the final answer or uses a model-visible handoff
  # tool to choose one of the next members allowed by the application.
  #
  #   class ProblemSolverSwarm < LittleGhost::Swarm
  #     member TriageAgent
  #     member BillingAgent
  #     member AccountAgent
  #
  #     start TriageAgent
  #     handoff TriageAgent, to: [BillingAgent, AccountAgent]
  #     max_steps 12
  #   end
  #
  #   run = ProblemSolverSwarm.ask("Why was I charged twice?")
  #   run.response
  #
  # Call a named Swarm with
  # ask[rdoc-ref:LittleGhost::Assembly.ask] for its final Run, or
  # the streaming entrypoint[rdoc-ref:LittleGhost::Assembly.stream_ask] for
  # coordination and final-response events.
  #
  # Swarm members are Agent definitions rather than arbitrary assemblies so a
  # handoff remains a direct model-to-model transition. Original conversation
  # history and application context stay isolated unless a member opts in with
  # <tt>history: true</tt> or <tt>context: true</tt>. Streams expose coordination
  # events and the final member response, but not intermediate model text.
  class Swarm < Assembly
    MAX_BUFFERED_EVENTS = 10_000 # :nodoc:
    MAX_BUFFERED_EVENT_BYTES = 10 * 1024 * 1024 # :nodoc:
    Member = Data.define(:id, :agent, :policies, :inherit_history, :inherit_context) # :nodoc:
    Handoff = Data.define(:from, :to) # :nodoc:

    extend Support::ClassAttributes

    class_attribute :swarm_members_value, default: {}.freeze
    class_attribute :swarm_handoffs_value, default: [].freeze
    class_attribute :swarm_start_value
    class_attribute :swarm_max_steps_value, default: 20
    class_attribute :swarm_max_handoff_repeats_value, default: 3

    class << self
      # Declares one Agent member and its optional execution policy.
      def member(agent, as: nil, timeout: nil, retries: 0, retry_on: nil, retry_delay: 0,
        history: false, context: false)
        validate_agent_reference!(agent)
        id = normalize_member_id(as || agent_reference_id(agent))
        raise ConfigurationError, "swarm member #{id.inspect} is already declared" if swarm_members_value.key?(id)
        unless [history, context].all? { |value| value == true || value == false }
          raise ArgumentError, "swarm member history and context options must be true or false"
        end

        policies = {timeout:, retries:, retry_on:, retry_delay:}.freeze
        declaration = Member.new(
          id:, agent:, policies:,
          inherit_history: history,
          inherit_context: context
        )
        self.swarm_members_value = swarm_members_value.merge(id => declaration).freeze
      end

      # Reads or assigns the initial Agent member.
      def start(member = nil)
        return swarm_start_value if member.nil?

        self.swarm_start_value = normalize_member_id(member_reference_id(member))
      end

      # Restricts one member to the declared handoff targets.
      def handoff(from, to:)
        from = normalize_member_id(member_reference_id(from))
        targets = Array(to).map { |target| normalize_member_id(member_reference_id(target)) }
        raise ArgumentError, "handoff requires at least one target" if targets.empty?
        raise ArgumentError, "handoff targets must be unique" unless targets.uniq.length == targets.length

        declaration = Handoff.new(from:, to: targets.freeze)
        self.swarm_handoffs_value = (swarm_handoffs_value + [declaration]).freeze
        declaration
      end

      # Reads or assigns the maximum member executions.
      def max_steps(value = nil)
        return swarm_max_steps_value if value.nil?

        value = Integer(value)
        raise ArgumentError, "max_steps must be at least 1" if value < 1

        self.swarm_max_steps_value = value
      end

      # Reads or assigns how often the same directed handoff may repeat.
      #
      # For example, a value of +2+ allows the transition from triage to billing
      # twice during one Swarm run. +max_steps+ still limits total member calls.
      def max_handoff_repeats(value = nil)
        return swarm_max_handoff_repeats_value if value.nil?

        value = Integer(value)
        raise ArgumentError, "max_handoff_repeats must be at least 1" if value < 1

        self.swarm_max_handoff_repeats_value = value
      end

      # Validates the members and allowed handoff routes, then returns this class.
      def validate!
        swarm_definition!
        self
      end

      def swarm_definition! # :nodoc:
        members = swarm_members_value
        start_id = swarm_start_value
        raise ConfigurationError, "swarm must declare at least two members" if members.length < 2
        raise ConfigurationError, "swarm must declare a start member" unless start_id
        raise ConfigurationError, "swarm start member #{start_id.inspect} is not declared" unless members.key?(start_id)

        seen_sources = {}
        members.each_value { |member| validate_step_policy!(member.policies) }
        swarm_handoffs_value.each do |declaration|
          raise ConfigurationError, "swarm handoff source #{declaration.from.inspect} is not declared" unless members.key?(declaration.from)
          if seen_sources[declaration.from]
            raise ConfigurationError, "swarm member #{declaration.from.inspect} has more than one handoff declaration"
          end
          seen_sources[declaration.from] = true
          declaration.to.each do |target|
            raise ConfigurationError, "swarm handoff target #{target.inspect} is not declared" unless members.key?(target)
            raise ConfigurationError, "swarm member #{target.inspect} cannot hand off to itself" if target == declaration.from
          end
        end
        [members, start_id, swarm_handoffs_value]
      end

      private

      def validate_agent_reference!(value)
        valid = (value.is_a?(Class) && value <= Agent) ||
          value.is_a?(AgentBuilder) ||
          (value.is_a?(AssemblyDefinition) && value.kind == :agent)
        raise ConfigurationError, "swarm members must be Agent definitions" unless valid
      end

      def agent_reference_id(value)
        return value.agent_id if value.is_a?(Class)

        value.assembly_id
      end

      def member_reference_id(value)
        return agent_reference_id(value) if value.is_a?(Class) || value.is_a?(AgentBuilder) || value.is_a?(AssemblyDefinition)

        value
      end

      def normalize_member_id(value)
        value = value.to_s
        raise ArgumentError, "swarm member id cannot be empty" if value.empty?

        value.freeze
      end
    end

    def initialize(run: nil, runtime: nil) # :nodoc:
      super(run:, runtime:, standalone: run.nil?)
      @swarm_mutex = Mutex.new
      @swarm_started = false
    end

    # Streams lifecycle events and only the final member's answer events.
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
      current_input = input.is_a?(Message) ? input : Message.new(role: :user, content: input)
      original_history = normalize_history(history)
      original_context = isolated_assembly_state(context || {})
      settings ||= {}
      template_locals ||= {}
      template_paths ||= []

      usage = Usage.new
      error_emitted = false
      Enumerator.new do |events|
        members, current, topology = self.class.swarm_definition!
        steps = []
        transitions = Hash.new(0)
        step_number = 0
        previous_step_id = nil

        loop do
          check_swarm_control!(cancellation_token, deadline, step_number)
          step_number += 1
          member = members.fetch(current)
          allowed = allowed_targets(current, members, topology)
          handoff_tool = handoff_tool_for(current, allowed, members) if allowed.any?
          step_id = SecureRandom.uuid
          events << StreamEvent.build(
            :assembly_step_start,
            assembly_id: self.class.assembly_id,
            assembly_kind: :swarm,
            step: step_number,
            participant: current,
            step_id:
          )
          execution = execute_assembly_step(
            reference: member.agent,
            participant: current,
            input: current_input,
            history: member.inherit_history ? original_history : [],
            context: member.inherit_context ? original_context : {},
            cancellation_token:, deadline:, settings:, template_locals:,
            template_paths:, parent_operation_id:,
            policies: member.policies,
            predecessor_ids: Array(previous_step_id),
            checkpoint: nil,
            build_options: {tools: [handoff_tool].compact},
            step_id:
          ) { |event| events << event }
          result = execution.result
          previous_step_id = execution.step.id
          transition = active_transition(execution, allowed)
          events << StreamEvent.build(
            :assembly_step_stop,
            assembly_id: self.class.assembly_id,
            assembly_kind: :swarm,
            step: step_number,
            participant: current,
            step_id: execution.step.id,
            usage: execution.step.usage
          )

          if transition
            usage += execution.step.usage
            target = transition.fetch(:agent_id)
            key = [current, target]
            transitions[key] += 1
            if transitions[key] > self.class.max_handoff_repeats
              events << StreamEvent.build(
                :assembly_handoff_loop,
                assembly_id: self.class.assembly_id,
                assembly_kind: :swarm,
                from: current,
                to: target,
                count: transitions[key]
              )
              raise AssemblyLimitError, "swarm repeated handoff #{current.inspect} -> #{target.inspect} too many times"
            end
            sanitized = sanitized_handoff_step(execution.step, transition)
            steps << sanitized
            steps.concat(result.steps.drop(1))
            events << StreamEvent.build(
              :assembly_transition,
              assembly_id: self.class.assembly_id,
              assembly_kind: :swarm,
              step: step_number,
              from: current,
              to: target
            )
            current_input = handoff_input(from: current, transition:)
            current = target
            next
          end

          usage += execution.step.usage
          steps.concat(result.steps)
          final = copy_run_result(result, usage:, steps: steps.freeze)
          release_final_events(execution.events, final).each { |event| events << event }
          break
        end
      rescue => error
        usage += step_error_usage(error)
        unless error_emitted
          events << StreamEvent.build(:invocation_error, error:, usage:, metadata: {})
        end
        raise
      end
    end

    private

    def reserve_execution!
      @swarm_mutex.synchronize do
        raise Error, "swarm instances can only be streamed once" if @swarm_started

        @swarm_started = true
      end
    end

    def check_swarm_control!(token, deadline, step)
      token.raise_if_cancelled!
      raise DeadlineExceededError, "The run deadline was reached" if deadline && Time.now >= deadline
      if step >= self.class.max_steps
        raise AssemblyLimitError, "#{self.class} reached its max_steps limit of #{self.class.max_steps}"
      end
    end

    def allowed_targets(current, members, topology)
      return members.keys.reject { |id| id == current } if topology.empty?

      topology.find { |declaration| declaration.from == current }&.to || []
    end

    def handoff_tool_for(current, allowed, members)
      descriptions = allowed.map do |id|
        member = members.fetch(id)
        description = member_description(member.agent)
        description.empty? ? id : "#{id}: #{description}"
      end.join("; ")
      Class.new(Tool) do
        tool_name "handoff_to_agent"
        description "Hand the request to one available swarm member: #{descriptions}"
        input_schema(
          type: "object",
          properties: {
            agent_id: {type: "string", enum: allowed},
            message: {type: "string"},
            context: {type: "object", additionalProperties: true}
          },
          required: %w[agent_id message],
          additionalProperties: false
        )

        define_method(:call) do |input|
          payload = {
            agent_id: input.fetch("agent_id"),
            message: input.fetch("message"),
            context: input["context"]
          }.compact.freeze
          agent.request_assembly_transition(payload, context: context)
          "Handing off to #{payload.fetch(:agent_id)}."
        end
      end
    end

    def member_description(reference)
      return reference.description if reference.respond_to?(:description)
      return reference.implementation.description if reference.is_a?(AssemblyDefinition)

      ""
    end

    def active_transition(execution, allowed)
      transition = execution.transition
      return nil unless transition
      unless transition.is_a?(Hash)
        raise ProtocolError, "swarm member requested a handoff without a transition payload"
      end
      target = transition[:agent_id] || transition["agent_id"]
      raise AssemblyRoutingError, "swarm member selected unavailable target #{target.inspect}" unless allowed.include?(target)

      {agent_id: target, message: transition[:message] || transition["message"], context: transition[:context] || transition["context"]}.compact
    end

    def sanitized_handoff_step(step, transition)
      output, truncated = projected_step_output(transition)
      Step.new(**step.to_h.merge(output:, output_truncated: truncated))
    end

    def step_error_usage(error) = error.instance_variable_get(:@little_ghost_step_usage) || Usage.new

    def handoff_input(from:, transition:)
      text = "Handoff from #{from}:\n#{transition.fetch(:message)}"
      if transition[:context]
        text << "\n\nAdditional context supplied by the previous agent:\n"
        text << JSON.generate(transition.fetch(:context))
      end
      Message.new(role: :user, content: text)
    rescue JSON::GeneratorError
      raise AssemblyRoutingError, "swarm handoff context must be JSON-compatible"
    end

    def release_final_events(events, final)
      buffer = []
      bytes = 0
      events.each do |event|
        event = StreamEvent.build(event.type, **event.data.merge(result: final)) if event.type == :invocation_stop
        bytes = buffer_event!(buffer, event, bytes:)
      end
      buffer
    end

    def buffer_event!(buffer, event, bytes:)
      raise AssemblyLimitError, "swarm member emitted too many buffered events" if buffer.length >= MAX_BUFFERED_EVENTS

      bytes += buffered_size(event)
      raise AssemblyLimitError, "swarm member emitted too much buffered event data" if bytes > MAX_BUFFERED_EVENT_BYTES

      buffer << event
      bytes
    end

    def buffered_size(value, ancestors = {}, depth = 0)
      return MAX_BUFFERED_EVENT_BYTES + 1 if depth > 32

      identity = value.object_id
      return 0 if ancestors.key?(identity)

      case value
      when String
        value.bytesize
      when Hash
        ancestors[identity] = true
        value.sum { |key, item| buffered_size(key, ancestors, depth + 1) + buffered_size(item, ancestors, depth + 1) }
      when Array
        ancestors[identity] = true
        value.sum { |item| buffered_size(item, ancestors, depth + 1) }
      when Data
        ancestors[identity] = true
        value.members.sum { |member| buffered_size(value.public_send(member), ancestors, depth + 1) }
      else
        64
      end
    ensure
      ancestors.delete(identity) if identity
    end

    def normalize_history(value)
      return [].freeze if value.nil?

      Array(value).map { |message| Message.coerce(message) }.freeze
    end
  end
end
