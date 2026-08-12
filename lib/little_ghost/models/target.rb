# frozen_string_literal: true

module LittleGhost
  module Models
    # Identifies one physical model through a named provider connection.
    Target = Data.define(:provider, :model_id) do
      def initialize(provider:, model_id:)
        provider = provider.to_s.strip
        model_id = model_id.to_s.strip
        raise ConfigurationError, "Model target provider is required" if provider.empty?
        raise ConfigurationError, "Model target model ID is required" if model_id.empty?

        super(provider: provider.freeze, model_id: model_id.freeze)
      end

      # Parses +provider:model-id+, splitting only at the first colon.
      def self.parse(value)
        return value if value.is_a?(self)

        provider, separator, model_id = value.to_s.partition(":")
        raise ConfigurationError, "Model target must use provider:model-id" if separator.empty?

        new(provider:, model_id:)
      end

      def to_s = "#{provider}:#{model_id}"
    end
  end
end
