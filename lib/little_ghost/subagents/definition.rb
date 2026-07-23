# frozen_string_literal: true

module LittleGhost
  module Subagents
    class Definition
      attr_reader :kind, :description, :factory

      def initialize(kind:, description:, factory:)
        @kind = String(kind)
        @description = String(description)
        @factory = factory

        raise ArgumentError, "kind cannot be empty" if @kind.empty?
        raise ArgumentError, "factory must respond to call" unless @factory.respond_to?(:call)
      end
    end
  end
end
