# frozen_string_literal: true

module LittleGhost
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class InvocationError < Error; end
  class UnsupportedInputError < InvocationError; end
  class ProviderError < Error; end
  class ProtocolError < ProviderError; end
  class ContextWindowOverflowError < ProviderError; end
  class OutputLimitError < ProtocolError; end
  class MalformedToolCallError < ProtocolError; end

  class StructuredResultError < ProtocolError
    attr_reader :schema_name, :validation_errors

    def initialize(message, schema_name:, validation_errors: [])
      @schema_name = schema_name.to_s.freeze
      @validation_errors = Array(validation_errors).map(&:to_s).freeze
      super(message)
    end
  end

  class ToolLoopError < ProtocolError; end
  class ToolError < Error; end
  class CancelledError < Error; end
  class DeadlineExceededError < Error; end
  class CleanupError < Error; end
end
