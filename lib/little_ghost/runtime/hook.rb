# frozen_string_literal: true

module LittleGhost
  class Runtime
    # Hooks let applications prepare runs, select session history, transform
    # interjections, and map errors to caller-safe messages.
    #
    # Hooks are instantiated once per Runtime in configuration order. Override
    # only the methods needed and return the supplied value when leaving it
    # unchanged.
    #
    #   class TenantHook < LittleGhost::Runtime::Hook
    #     def prepare_run(run)
    #       run.register(TenantConnection.new(run.invocation.actor_id))
    #       run
    #     end
    #   end
    class Hook
      # Prepares a newly built Run. Resources registered on the run share its
      # lifecycle and close in reverse order.
      def prepare_run(run) = run

      # Prepares a Run after its Workspace and Sandbox have opened, but before
      # session history or the entrypoint Agent is built. Hooks may safely
      # store run-scoped files here.
      def prepare_execution(run) = run

      # Transforms an interjection payload before it reaches the agent.
      def prepare_interjection(_run, payload) = payload

      # Returns the history to use for this run, or nil to defer to later hooks
      # and the session default. +stored+ is empty when the session is new;
      # +fallback+ contains messages supplied by the invocation.
      def session_history(_run, stored:, fallback:) = nil

      # Returns a caller-safe error message, or nil to defer to later hooks and
      # the runtime default. Avoid exposing secrets or internal exception text.
      def error_message(_error, _run) = nil
    end
  end
end
