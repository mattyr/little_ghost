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
    def capabilities = ModelCapabilities.permissive
  end

  # Model is the resolved connection between an agent selection and a provider.
  # It keeps provider behavior behind one executable interface whether an agent
  # selected a role, canonical target, or inline configuration.
  #
  # It merges profile settings into every ModelRequest, validates attachment
  # modalities declared in metadata, lets providers prepare capability-sensitive
  # requests, and delegates the normalized stream to the provider.
  class Model
    include ModelInterface

    # Provider object, canonical target, default settings, normalized model
    # details, and logical application role.
    attr_reader :provider, :target, :settings, :details, :role

    # Connects a provider adapter to its canonical +target+, profile +settings+,
    # optional model +details+, and logical +role+.
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
      validate_input_modalities!(request)
      configured_settings = settings.merge(request.settings)
      configured_max_tokens = if request.settings.key?(:max_tokens)
        request.settings[:max_tokens]
      elsif request.settings.key?("max_tokens")
        request.settings["max_tokens"]
      else
        settings[:max_tokens] || settings["max_tokens"]
      end
      if configured_max_tokens && details.max_output_tokens
        configured_settings.delete(:max_tokens)
        configured_settings.delete("max_tokens")
        configured_settings[:max_tokens] = [configured_max_tokens, details.max_output_tokens].min
      end
      configured_request = ModelRequest.new(
        messages: request.messages,
        tools: request.tools,
        settings: configured_settings,
        output_schema: request.output_schema,
        tool_choice: request.tool_choice,
        required_capabilities: request.required_capabilities,
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
      configured_request = provider.prepare_request(configured_request, capabilities:)
      provider.stream(configured_request, &block)
    end

    # Executes an embedding request through the configured provider.
    def embed(request)
      configured = Embeddings::Request.new(
        inputs: request.inputs,
        settings: settings.merge(request.settings),
        limits: request.limits,
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
      response = provider.embed(configured)
      unless response.is_a?(Embeddings::Response) && response.vectors.length == configured.inputs.length
        raise ProtocolError, "Embedding provider returned an unexpected vector count"
      end

      response
    end

    # Uses advertised provider capabilities.
    def capabilities
      @capabilities ||= provider.capabilities(metadata: details.attributes)
    end

    private

    def validate_input_modalities!(request)
      supported = details.input_modalities
      return unless supported

      required = request.messages.flat_map do |message|
        message.content.filter_map do |block|
          case block
          when Content::Image then "image"
          when Content::Document then (block.media_type == "application/pdf") ? "pdf" : "file"
          end
        end
      end.uniq
      available = Array(supported).map { |value| value.to_s.downcase }
      missing = required.reject do |modality|
        available.include?(modality) || (modality == "pdf" && available.include?("file"))
      end
      return if missing.empty?

      raise UnsupportedInputError,
        "The selected model does not support #{missing.join(" and ")} attachments. Choose a compatible model or remove those attachments."
    end
  end
end
