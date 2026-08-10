# frozen_string_literal: true

module LittleGhost
  # Subagents let one agent hand focused work to other agents and continue the
  # conversation when those agents finish.
  module Subagents
    # A Definition describes one kind of agent available for delegation. Most
    # applications create definitions through Agent::Delegation#subagent.
    #
    # The factory receives the complete agent path and may also accept
    # +runtime:+. When +accepts_conversation_id+ is true it receives the durable
    # conversation UUID as a second positional argument. Factories returning a
    # LittleGhost::Agent must construct it with the supplied path as
    # +agent_path+; the conversation UUID is a separate persistence identifier.
    #
    #   # ResearchAgent is defined by the application.
    #   definition = LittleGhost::Subagents::Definition.new(
    #     kind: "research",
    #     description: "Investigates a bounded question",
    #     factory: ->(agent_path) { ResearchAgent.new(agent_path:) }
    #   )
    #   definition.kind # => "research"
    class Definition
      # The model-visible kind and description, callable factory, persistence
      # policy, and factory-arity declaration.
      attr_reader :kind, :description, :factory, :persist, :accepts_conversation_id

      # Validates a definition. +persist+ is effective only when the
      # manager has a parent session.
      def initialize(kind:, description:, factory:, persist: true, accepts_conversation_id: false)
        @kind = String(kind)
        @description = String(description)
        @factory = factory
        @persist = !!persist
        @accepts_conversation_id = !!accepts_conversation_id

        raise ArgumentError, "kind cannot be empty" if @kind.empty?
        raise ArgumentError, "factory must respond to call" unless @factory.respond_to?(:call)
      end
    end
  end
end
