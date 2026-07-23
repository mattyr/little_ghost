# frozen_string_literal: true

module LittleGhost
  module Support
    module_function

    def immutable(value)
      case value
      when Hash
        value.to_h { |key, child| [immutable(key), immutable(child)] }.freeze
      when Array
        value.map { |child| immutable(child) }.freeze
      when String
        value.dup.freeze
      else
        value
      end
    end
  end
end

require_relative "support/callbacks"
require_relative "support/cancellation_token"
require_relative "support/content_capture"
require_relative "support/executor"
require_relative "support/interruptible_stream"
require_relative "support/instrumentation"
require_relative "support/loader"
