# frozen_string_literal: true

module LittleGhost
  # Support collects small building blocks for LittleGhost extensions. They are
  # available to applications that need the same cancellation, loading,
  # callback, execution, and diagnostic behavior as the framework.
  module Support
    module_function

    # Recursively duplicates hashes, arrays, and strings while preserving other
    # values. Cyclic containers are not supported.
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
require_relative "support/redactor"
require_relative "support/content_capture"
require_relative "support/executor"
require_relative "support/interruptible_stream"
require_relative "support/loader"
