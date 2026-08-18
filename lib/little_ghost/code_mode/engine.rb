# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Adapter contract for a code-mode language.
    #
    # An Engine describes the language shown to the model and opens one Session.
    # Model-authored code must run behind the supplied +sandbox_factory+. The
    # Broker must remain in the trusted parent process; do not expose it or its
    # application objects inside the child interpreter.
    class Engine
      # Returns the engine's language identifier as a Symbol.
      def language = raise(AbstractMethodError, "engine must report its language")

      # Returns model-facing instructions for the supplied Tool Catalog.
      # Instructions must describe only names and behavior the Session actually
      # implements.
      def instructions(catalog:) = raise(AbstractMethodError, "engine must provide instructions")

      # Opens and returns a CodeMode::Session.
      #
      # +broker+ is called only from trusted parent code. +sandbox_factory+
      # creates the Sandbox that contains model-authored execution. +limits+ is
      # the application's mapping, passed through unchanged. A custom Engine
      # must normalize keys and values, validate supported settings, and merge
      # its own safe defaults. The Session owns every Workspace, Sandbox,
      # process, thread, and channel it creates.
      def open_session(broker:, sandbox_factory:, limits:) = raise(AbstractMethodError, "engine must open a session")

      private

      def normalize_limits(limits, defaults:)
        configured = limits.to_h.transform_keys(&:to_sym)
        unsupported = configured.keys - defaults.keys
        unless unsupported.empty?
          names = unsupported.sort_by(&:to_s).map(&:inspect).join(", ")
          raise ArgumentError, "unsupported code-mode limits: #{names}"
        end

        defaults.merge(configured)
      end

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
