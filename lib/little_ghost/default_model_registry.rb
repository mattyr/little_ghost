# frozen_string_literal: true

module LittleGhost
  # Supplies LittleGhost's ready-to-use model selection. The registry maps the
  # +default+ role to GPT-5.6 Terra on OpenRouter or OpenAI and keeps the selected
  # provider stable for its runtime.
  #
  # Prefixed credentials take precedence over conventional provider variables:
  #
  # 1. +LITTLEGHOST_OPENROUTER_API_KEY+
  # 2. +LITTLEGHOST_OPENAI_API_KEY+
  # 3. +OPENROUTER_API_KEY+
  # 4. +OPENAI_API_KEY+
  #
  # Blank values are ignored. Resolving the +default+ role requires one supported
  # key and raises ConfigurationError with the available choices otherwise. The
  # environment is read when the registry is created, so build a new Runtime
  # after changing credentials. Configure a ModelRegistry explicitly when the
  # application needs another provider, model, or logical role.
  #
  # *Warning:* Setting any supported key authorizes LittleGhost to send model
  # inputs, including prompts, conversation history, tool data, and attachments,
  # to the selected external provider. When more than one key is present, the
  # precedence above determines that destination. Applications with provider or
  # data-residency requirements should configure a ModelRegistry explicitly.
  class DefaultModelRegistry < ModelRegistry
    CREDENTIALS = [
      ["LITTLEGHOST_OPENROUTER_API_KEY", :openrouter],
      ["LITTLEGHOST_OPENAI_API_KEY", :openai],
      ["OPENROUTER_API_KEY", :openrouter],
      ["OPENAI_API_KEY", :openai]
    ].freeze # :nodoc:
    MODELS = {
      openrouter: "openai/gpt-5.6-terra",
      openai: "gpt-5.6-terra"
    }.freeze # :nodoc:
    PROVIDERS = {
      openrouter: Providers::OpenRouter,
      openai: Providers::OpenAI
    }.freeze # :nodoc:
    MISSING_CREDENTIAL_MESSAGE =
      "No API key is configured for the default model. Set " \
      "LITTLEGHOST_OPENROUTER_API_KEY, LITTLEGHOST_OPENAI_API_KEY, " \
      "OPENROUTER_API_KEY, or OPENAI_API_KEY, or configure a custom " \
      "model registry with LittleGhost.configure." # :nodoc:

    # Selects one provider from the current environment and registers the
    # +default+ profile. The selection remains fixed for this registry instance.
    def initialize
      super
      variable, provider_name = CREDENTIALS.find { |name, _provider| !ENV[name].to_s.strip.empty? }
      if variable
        api_key = ENV.fetch(variable)
        provider_class = PROVIDERS.fetch(provider_name)
        provider(provider_name) do |model:, **|
          provider_class.new(api_key:, model:)
        end
        profile("default", provider: provider_name, model: MODELS.fetch(provider_name))
      else
        configure_missing_credential
      end
    end

    private

    def configure_missing_credential
      provider(:unconfigured) { |**| raise ConfigurationError, MISSING_CREDENTIAL_MESSAGE }
      profile("default", provider: :unconfigured, model: MODELS.fetch(:openai))
    end
  end
end
