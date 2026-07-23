# frozen_string_literal: true

module LittleGhost
  class Model
    IDENTITY_METADATA_KEYS = %w[provider model_id model_role].freeze

    attr_reader :provider, :provider_name, :id, :settings, :metadata, :role

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

    def stream(request, &block)
      validate_input_modalities!(request)
      configured_request = ModelRequest.new(
        messages: request.messages,
        tools: request.tools,
        settings: settings.merge(request.settings),
        cancellation_token: request.cancellation_token,
        deadline: request.deadline
      )
      provider.stream(configured_request, &block)
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
