# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Base contract implemented by language engines.
    class Engine
      def language = raise(AbstractMethodError, "engine must report its language")
      def instructions(catalog:) = raise(AbstractMethodError, "engine must provide instructions")
      def open_session(broker:, sandbox_factory:, limits:) = raise(AbstractMethodError, "engine must open a session")

      private

      def allow_subprocesses_for(sandbox)
        capabilities = sandbox.capabilities
        return true if capabilities.supports?(:process_tree_ownership)
        return false if capabilities.supports?(:process_spawn_denial)
        return true if capabilities.isolation == :none

        raise CapabilityError, "code mode requires owned subprocesses or enforced subprocess denial"
      end
    end
  end
end
