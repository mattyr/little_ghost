# frozen_string_literal: true

module LittleGhost
  # Base class for LittleGhost domain errors. Public APIs may also raise Ruby
  # errors such as ArgumentError for invalid method arguments.
  class Error < StandardError; end
  # Raised for invalid framework or application configuration. Correct the
  # configuration before retrying the request.
  class ConfigurationError < Error; end
  # Base class for sandbox setup failures that trusted application code can
  # diagnose before model-controlled work starts.
  class SandboxConfigurationError < ConfigurationError; end
  # Raised when a sandbox backend does not support the current operating system.
  class UnsupportedPlatformError < SandboxConfigurationError; end
  # Raised when an explicitly selected sandbox backend dependency is unavailable.
  class DependencyError < SandboxConfigurationError; end
  # Raised when a backend cannot enforce a requested sandbox capability.
  class CapabilityError < SandboxConfigurationError; end
  # Raised when a sandbox policy is internally invalid.
  class PolicyError < SandboxConfigurationError; end
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
  # Base class for provider request, response, and protocol failures. Agent Runs
  # normally record these as failed outcomes; provider retry policy may handle a
  # retryable failure before it reaches the Run.
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
  # Base class for expected failures while executing a Tool. Its message may be
  # returned to the model, so it must be safe to disclose.
  class ToolError < Error; end
  # Raised when an active run cannot accept an interjection.
  class AgentInterjectionError < InvocationError; end
  # Raised when cancellation stops an operation. A started top-level Run
  # normally records a cancelled outcome.
  class CancelledError < Error; end
  # Raised when an operation reaches its deadline. A started top-level Run
  # normally records a partial outcome.
  class DeadlineExceededError < Error; end
  # Raised when one or more managed resources fail to close. Treat the operation
  # as not cleanly terminated and escalate to the application's supervisor.
  class CleanupError < Error; end
end
