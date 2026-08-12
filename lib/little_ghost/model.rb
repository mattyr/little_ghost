# frozen_string_literal: true

module LittleGhost
  # Interface for executable model implementations accepted by agents.
  module ModelInterface
    # Canonical physical provider and model identifier.
    def target = Models::Target.parse("custom:#{self.class.name || "anonymous"}")
    # Provider-owned model identifier without the connection name.
    def model_id = target.model_id
    # Logical application role that selected this model, when available.
    def role = nil
    # Immutable capabilities, limits, modalities, and pricing facts.
    def details = Models::Details.new(target:)
    # Normalized feature support used for request strategy selection.
    def capabilities = ModelCapabilities.legacy
  end

  # Model is the configured connection between an agent role and a provider. It
  # keeps provider choice and defaults out of the agent class that uses them.
  #
  # It merges profile settings into every ModelRequest, validates attachment
  # modalities declared in metadata, lets providers prepare capability-sensitive
  # requests, and delegates the normalized stream to the provider.
  class Model
    include ModelInterface

    # Provider object, canonical target, default settings, normalized model
    # details, and logical application role.
    attr_reader :provider, :target, :settings, :details, :role

    # Wraps an object that responds to +stream+.
    def initialize(provider:, target:, settings: {}, details: nil, role: nil)
      raise ArgumentError, "provider must be a LittleGhost::Providers::Base" unless provider.is_a?(Providers::Base)

      @provider = provider
      @target = Models::Target.parse(target)
      @settings = settings.to_h.transform_keys(&:to_sym).freeze
      @role = role&.to_s
      @details = details || Models::Details.new(target: @target)
    end

    # Provider-owned identifier from the canonical target.
    def model_id = target.model_id

    # Streams +request+ through the configured provider.
    #
    # Profile settings are defaults; settings on +request+ take precedence.
    def stream(request, &block)
      configured_request = ModelRequest.new(
        messages: request.messages,
        tools: request.tools,
        settings: settings.merge(request.settings),
        output_schema: request.output_schema,
        tool_choice: request.tool_choice,
        required_capabilities: request.required_capabilities,
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
      configured_request = provider.prepare_request(configured_request, capabilities:)
      provider.stream(configured_request, &block)
    end

    # Uses advertised provider capabilities, falling back to the permissive legacy
    # contract for providers that do not advertise them.
    def capabilities
      @capabilities ||= provider.capabilities(metadata: details.attributes)
    end
  end
end
