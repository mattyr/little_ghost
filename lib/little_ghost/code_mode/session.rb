# frozen_string_literal: true

module LittleGhost
  module CodeMode
    # Base contract implemented by one engine session.
    class Session
      def execute(source:, catalog:, frame: nil, yield_time_ms: nil, max_output_tokens: nil, context: nil)
        raise AbstractMethodError, "session must execute source"
      end

      def wait(yield_time_ms: nil, max_output_tokens: nil, terminate: false, context: nil)
        raise AbstractMethodError, "session does not support waiting"
      end

      def close = nil
    end
  end
end
