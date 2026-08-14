# frozen_string_literal: true

module LittleGhost
  # Base class for errors raised by LittleGhost.
  class Error < StandardError; end
  # Raised for invalid framework or application configuration.
  class ConfigurationError < Error; end
  # Raised when an abstract framework method has no concrete implementation.
  class AbstractMethodError < Error; end
  # Raised when a configured provider adapter cannot be constructed.
  class AdapterLoadError < ConfigurationError; end
  # Raised when no usable credentials can be resolved for a provider.
  class CredentialError < ConfigurationError; end
  # Raised when an invocation payload or operation is invalid.
  class InvocationError < Error; end
  # Base class for failures coordinating one or more assemblies.
  class AssemblyError < Error; end
  # Raised when an assembly exceeds its configured execution bound.
  class AssemblyLimitError < AssemblyError; end
  # Raised when an assembly cannot choose one valid next participant.
  class AssemblyRoutingError < AssemblyError; end
  # Raised when one assembly step exceeds its local timeout.
  class AssemblyStepTimeoutError < AssemblyError; end
  # Raised when an invocation contains an unsupported input form.
  class UnsupportedInputError < InvocationError; end
  # Base class for provider response and protocol failures.
  class ProviderError < Error; end
  # Raised when a provider violates the expected request-response protocol.
  class ProtocolError < ProviderError; end
  # Raised when a provider reports that the request exceeds its context window.
  class ContextWindowOverflowError < ProviderError; end
  # Raised when configured generation limits stop the agent before completion.
  class OutputLimitError < ProtocolError; end
  # Raised when a model returns an invalid tool-call representation.
  class MalformedToolCallError < ProtocolError; end

  # Raised when structured output is absent, invalid, or exceeds safety limits.
  class StructuredResultError < ProtocolError
    # Declared schema name and validation messages returned by local checking.
    attr_reader :schema_name, :validation_errors

    # Records the schema and freezes normalized validation messages.
    def initialize(message, schema_name:, validation_errors: [])
      @schema_name = schema_name.to_s.freeze
      @validation_errors = Array(validation_errors).map(&:to_s).freeze
      super(message)
    end
  end

  # Raised when repeated identical tool calls reach the configured termination limit.
  class ToolLoopError < ProtocolError; end
  # Base class for failures while executing a tool.
  class ToolError < Error; end
  # Raised when an active run cannot accept an interjection.
  class AgentInterjectionError < InvocationError; end
  # Raised when cancellation stops an operation.
  class CancelledError < Error; end
  # Raised when an operation reaches its deadline.
  class DeadlineExceededError < Error; end
  # Raised when one or more managed resources fail to close.
  class CleanupError < Error; end
end
