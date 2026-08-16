# frozen_string_literal: true

module LittleGhost
  AgentStreamStep = Data.define( # :nodoc:
    :assembly_id,
    :assembly_kind,
    :participant,
    :step_id,
    :branch_id
  ) do
    def self.build(assembly_id:, assembly_kind:, participant:, step_id:, branch_id: nil)
      new(
        assembly_id: assembly_id.to_s.dup.freeze,
        assembly_kind: assembly_kind.to_sym,
        participant: participant.to_s.dup.freeze,
        step_id: step_id.to_s.dup.freeze,
        branch_id: branch_id&.to_s&.dup&.freeze
      ).freeze
    end
  end

  # Identifies one assembly step in the path to a streamed Agent invocation.
  # Paths list outer steps before inner steps, so the final value identifies the
  # participant that directly contains the Agent.
  class AgentStreamStep < Data # :doc:
    ##
    # :attr_reader: assembly_id
    # Stable String identifier for the containing assembly.

    ##
    # :attr_reader: assembly_kind
    # The +:workflow+, +:swarm+, +:graph+, or custom assembly kind.

    ##
    # :attr_reader: participant
    # String name used to route to this participant.

    ##
    # :attr_reader: step_id
    # Unique String identifier for this assembly step.

    ##
    # :attr_reader: branch_id
    # String branch identifier for a graph branch, or +nil+.

    ##
    # :singleton-method: build
    # :call-seq:
    #   build(assembly_id:, assembly_kind:, participant:, step_id:, branch_id: nil) -> AgentStreamStep
    #
    # Creates an immutable, normalized path step.
  end

  AgentStreamSource = Data.define( # :nodoc:
    :agent_id,
    :agent_path,
    :operation_id,
    :parent_operation_id,
    :assembly_path
  ) do
    def self.build(agent_id:, agent_path:, operation_id:, parent_operation_id:, assembly_path:)
      new(
        agent_id: agent_id.to_s.dup.freeze,
        agent_path: agent_path.to_s.dup.freeze,
        operation_id: operation_id.to_s.dup.freeze,
        parent_operation_id: parent_operation_id&.to_s&.dup&.freeze,
        assembly_path: Array(assembly_path).dup.freeze
      ).freeze
    end
  end

  # Describes which Agent produced an event during a Run.
  #
  # A +:agent_stream+ StreamEvent carries this value in +data[:source]+ and the
  # Agent's detached, deeply immutable StreamEvent snapshot in +data[:event]+.
  # +assembly_path+ is empty for a top-level Agent and contains one
  # AgentStreamStep for each enclosing composite assembly participant.
  class AgentStreamSource < Data # :doc:
    ##
    # :attr_reader: agent_id
    # Stable String identifier declared by the Agent class.

    ##
    # :attr_reader: agent_path
    # Stable subagent path, beginning at <tt>/root</tt>.

    ##
    # :attr_reader: operation_id
    # Unique String identifier for this Agent invocation.

    ##
    # :attr_reader: parent_operation_id
    # Parent operation identifier, or +nil+ when the caller did not supply one.

    ##
    # :attr_reader: assembly_path
    # Frozen Array of AgentStreamStep values from the outermost assembly inward.

    ##
    # :singleton-method: build
    # :call-seq:
    #   build(agent_id:, agent_path:, operation_id:, parent_operation_id:, assembly_path:) -> AgentStreamSource
    #
    # Creates an immutable, normalized source description.
  end

  module AgentStreamSnapshot # :nodoc: all
    module_function

    def event(event)
      data = copy(event.data)
      freeze_value(StreamEvent.build(event.type, **data))
    end

    def message(message)
      freeze_value(copy(message))
    end

    def copy(value, copies = {})
      return value if immutable_scalar?(value)
      return copies.fetch(value.object_id) if copies.key?(value.object_id)

      case value
      when Message
        copy_message(value, copies)
      when DataMap
        copy_data_map(value, copies)
      when Hash
        copy_hash(value, copies)
      when Array
        copy_array(value, copies)
      when String
        value.dup.freeze
      when Data
        copy_data(value, copies)
      when Exception
        copy_exception(value, copies)
      else
        copy_object(value, copies)
      end
    end

    def copy_message(value, copies)
      content = copy_array(value.content, copies)
      metadata = copy_data_map(value.metadata, copies)
      Message.new(role: value.role, content:, metadata:).freeze.tap do |snapshot|
        copies[value.object_id] = snapshot
      end
    end

    def copy_data_map(value, copies)
      snapshot = DataMap.new
      copies[value.object_id] = snapshot
      value.each do |key, child|
        snapshot[key] = copy(child, copies)
      end
      snapshot.freeze
    end

    def copy_hash(value, copies)
      snapshot = {}
      copies[value.object_id] = snapshot
      value.each do |key, child|
        snapshot[copy(key, copies)] = copy(child, copies)
      end
      snapshot.freeze
    end

    def copy_array(value, copies)
      snapshot = []
      copies[value.object_id] = snapshot
      value.each { |child| snapshot << copy(child, copies) }
      snapshot.freeze
    end

    def copy_data(value, copies)
      attributes = value.members.to_h do |member|
        [member, copy(value.public_send(member), copies)]
      end
      value.class.new(**attributes).freeze.tap do |snapshot|
        copies[value.object_id] = snapshot
      end
    end

    def copy_object(value, copies)
      return value if value.is_a?(Module)

      snapshot = value.dup
      copies[value.object_id] = snapshot
      value.instance_variables.each do |name|
        snapshot.instance_variable_set(name, copy(value.instance_variable_get(name), copies))
      end
      snapshot.freeze
    rescue TypeError
      value.frozen? ? value : value.to_s.dup.freeze
    end

    def copy_exception(value, copies)
      message = value.message.to_s.dup.freeze
      snapshot = value.exception(message)
      if snapshot.equal?(value)
        snapshot = value.class.allocate
        Exception.instance_method(:initialize).bind_call(snapshot, message)
      end
      copies[value.object_id] = snapshot
      if value.cause
        cause = copy(value.cause, copies)
        begin
          raise snapshot, cause:
        rescue => raised
          snapshot = raised
          copies[value.object_id] = snapshot
        end
      end
      value.instance_variables.each do |name|
        snapshot.instance_variable_set(name, copy(value.instance_variable_get(name), copies))
      end
      backtrace = copy(value.backtrace, copies)
      snapshot.set_backtrace(backtrace)
      freeze_value(snapshot.backtrace) if snapshot.backtrace
      snapshot.freeze
    end

    def immutable_scalar?(value)
      value.nil? || value == true || value == false || value.is_a?(Numeric) || value.is_a?(Symbol)
    end

    def freeze_value(value, seen = {})
      return value if immutable_scalar?(value) || value.is_a?(Module)
      return value if seen[value.object_id]

      seen[value.object_id] = true
      case value
      when Message
        freeze_value(value.content, seen)
        freeze_value(value.metadata, seen)
      when Hash
        value.each do |key, child|
          freeze_value(key, seen)
          freeze_value(child, seen)
        end
      when Array
        value.each { |child| freeze_value(child, seen) }
      when Data
        value.members.each { |member| freeze_value(value.public_send(member), seen) }
      else
        value.instance_variables.each do |name|
          freeze_value(value.instance_variable_get(name), seen)
        end
      end
      value.freeze
    end
  end

  class AgentStreamSink # :nodoc: all
    def initialize(destination:, run:, source:, input:)
      @destination = destination
      @run = run
      @source = source
      @input = input
    end

    def <<(event)
      data = {source: @source, event: AgentStreamSnapshot.event(event)}
      data[:input] = AgentStreamSnapshot.message(normalized_input) if event.type == :invocation_start
      @run.publish(:agent_stream, **data)
      @destination << event
    end

    private

    def normalized_input
      @input.is_a?(Message) ? @input : Message.new(role: :user, content: @input)
    end
  end
end
