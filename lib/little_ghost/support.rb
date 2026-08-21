# frozen_string_literal: true

module LittleGhost
  # Support collects small building blocks for LittleGhost extensions. They are
  # available to applications that need the same cancellation, loading,
  # callback, execution, and diagnostic behavior as the framework.
  module Support
    module_function

    # Recursively duplicates hashes, arrays, and strings while preserving other
    # values. Cyclic containers are not supported.
    def deep_dup(value, ancestors = {})
      if value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(Data)
        identity = value.object_id
        raise ArgumentError, "cyclic values cannot be duplicated" if ancestors.key?(identity)

        ancestors[identity] = true
      end
      case value
      when Hash
        value.each_with_object({}) do |(key, child), copy|
          copy[deep_dup(key, ancestors)] = deep_dup(child, ancestors)
        end
      when Array
        value.map { |child| deep_dup(child, ancestors) }
      when String
        value.dup
      when Data
        value.class.new(**value.to_h.transform_values { |child| deep_dup(child, ancestors) })
      else
        value
      end
    ensure
      ancestors.delete(identity) if identity
    end
  end
end

require_relative "support/callbacks"
require_relative "support/cancellation_token"
require_relative "support/class_attributes"
require_relative "support/redactor"
require_relative "support/content_capture"
require_relative "support/serialized_dispatcher"
require_relative "support/task"
require_relative "support/task_runner"
require_relative "support/executor"
require_relative "support/blocking_operation"
require_relative "support/interruptible_stream"
require_relative "support/loader"
