# frozen_string_literal: true

module LittleGhost
  # Runs model-authored orchestration code in a child interpreter. Built-in
  # engines keep Tool authority in the parent process: each Tool call returns to
  # a trusted Broker for catalog validation and ordinary Agent dispatch. Custom
  # engines must preserve the Engine and Session containment contracts.
  #
  # See the {Code Mode guide}[rdoc-ref:docs/guides/code_mode.md] for the first
  # Ruby cell, Broker boundary, lifecycle, limits, optional JavaScript engine,
  # and extension contract.
  module CodeMode
    @engines = {}

    class << self
      # Registers +implementation+ under a trusted engine name.
      def register_engine(name, implementation)
        unless engine_class?(implementation) || implementation.is_a?(Engine)
          raise ArgumentError, "code-mode engine must be an Engine class or instance"
        end

        engines[name.to_sym] = implementation
      end

      # Resolves a registered name or returns an explicit engine object.
      def resolve_engine(value)
        return engines.fetch(value.to_sym) { raise DependencyError, "code-mode engine :#{value} is not available" } if value.is_a?(Symbol) || value.is_a?(String)
        unless engine_class?(value) || value.is_a?(Engine)
          raise ArgumentError, "code-mode engine must be an Engine class or instance"
        end

        value
      end

      def engines # :nodoc:
        @engines ||= {}
      end

      private

      def engine_class?(value)
        value.is_a?(Class) && value <= Engine
      end
    end
  end
end

require_relative "code_mode/types"
require_relative "code_mode/engine"
require_relative "code_mode/session"
require_relative "code_mode/catalog"
require_relative "code_mode/broker"
require_relative "code_mode/protocol"
