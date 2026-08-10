# frozen_string_literal: true

module LittleGhost
  # Model is the configured connection between an agent role and a provider. It
  # keeps provider choice and defaults out of the agent class that uses them.
  #
  # It merges profile settings into every ModelRequest, validates attachment
  # modalities declared in metadata, lets providers prepare capability-sensitive
  # requests, and delegates the normalized stream to the provider.
  class Model
    IDENTITY_METADATA_KEYS = %w[provider model_id model_role].freeze # :nodoc:

    # Provider object and name, provider model ID, default settings, normalized
    # metadata, and logical application role.
    attr_reader :provider, :provider_name, :id, :settings, :metadata, :role

    # Wraps an object that responds to +stream+.
    def initialize(provider:, provider_name:, id: nil, model: nil, settings: {}, metadata: {}, role: nil)
      raise ArgumentError, "provider must respond to stream" unless provider.respond_to?(:stream)
      raise ArgumentError, "provider_name is required" if provider_name.nil? || provider_name.to_s.empty?
      raise ArgumentError, "model is required" if (id || model).nil? || (id || model).to_s.empty?

      @provider = provider
      @provider_name = provider_name.to_sym
      @id = (id || model)&.to_s
      @settings = settings.to_h.transform_keys(&:to_sym).freeze
      @role = role&.to_s
      profile_metadata = metadata.to_h.reject { |key, _value| IDENTITY_METADATA_KEYS.include?(key.to_s) }
      @metadata = profile_metadata.merge(
        provider: @provider_name,
        model_id: @id,
        model_role: @role
      ).freeze
    end

    # Streams +request+ through the configured provider.
    #
    # Profile settings are defaults; settings on +request+ take precedence.
    def stream(request, &block)
      validate_input_modalities!(request)
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
      if provider.respond_to?(:prepare_request)
        configured_request = provider.prepare_request(configured_request, capabilities:)
      end
      provider.stream(configured_request, &block)
    end

    # Uses advertised provider capabilities, falling back to the permissive legacy
    # contract for providers that do not advertise them.
    def capabilities
      @capabilities ||= if provider.respond_to?(:capabilities)
        provider.capabilities(metadata:)
      else
        ModelCapabilities.legacy
      end
    end

    private

    def validate_input_modalities!(request)
      supported = metadata[:input_modalities] || metadata["input_modalities"]
      return unless supported

      required = request.messages.flat_map do |message|
        message.content.filter_map do |block|
          case block
          when Content::Image then "image"
          when Content::Document then "file"
          end
        end
      end.uniq
      missing = required - Array(supported).map { |value| value.to_s.downcase }
      return if missing.empty?

      raise UnsupportedInputError,
        "The selected model does not support #{missing.join(" and ")} attachments. Choose a compatible model or remove those attachments."
    end
  end
end
