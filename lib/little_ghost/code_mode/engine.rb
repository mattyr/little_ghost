# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Base contract implemented by language engines.
    class Engine
      def language = raise(AbstractMethodError, "engine must report its language")
      def instructions(catalog:) = raise(AbstractMethodError, "engine must provide instructions")
      def open_session(broker:, sandbox_factory:, limits:) = raise(AbstractMethodError, "engine must open a session")
    end
  end
end
