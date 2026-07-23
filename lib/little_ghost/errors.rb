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
  class ToolLoopError < ProtocolError; end
  class ToolError < Error; end
  class CancelledError < Error; end
  class DeadlineExceededError < Error; end
  class CleanupError < Error; end
end
