# frozen_string_literal: true

module LittleGhost
  module Support
    module_function

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[deep_dup(key)] = deep_dup(child) }
      when Array
        value.map { |child| deep_dup(child) }
      when String
        value.dup
      else
        value
      end
    end
  end
end

require_relative "support/callbacks"
require_relative "support/cancellation_token"
require_relative "support/class_attributes"
require_relative "support/content_capture"
require_relative "support/executor"
require_relative "support/interruptible_stream"
require_relative "support/instrumentation"
require_relative "support/loader"
