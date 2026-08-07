# frozen_string_literal: true

module LittleGhost
  class Runtime
    class Hook
      def prepare_run(run) = run

      def prepare_interruption(_run, payload) = payload

      def error_message(_error, _run) = nil
    end
  end
end
