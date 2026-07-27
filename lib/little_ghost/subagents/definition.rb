# frozen_string_literal: true

module LittleGhost
  module Subagents
    class Definition
      attr_reader :kind, :description, :factory, :persist, :accepts_conversation_id

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
