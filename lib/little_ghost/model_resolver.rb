# frozen_string_literal: true

module LittleGhost
  # Resolves logical profiles and canonical +provider:model-id+ targets into
  # executable Model objects. Subclasses may override #resolve, #details, or
  # #refresh! while preserving those public signatures.
  class ModelResolver
    DEFAULT_CREDENTIALS = [
      ["LITTLEGHOST_OPENROUTER_API_KEY", "openrouter"],
      ["LITTLEGHOST_OPENAI_API_KEY", "openai"],
      ["OPENROUTER_API_KEY", "openrouter"],
      ["OPENAI_API_KEY", "openai"]
    ].freeze
    DEFAULT_MODELS = {
      "openrouter" => "openai/gpt-5.6-luna",
      "openai" => "gpt-5.6-luna"
    }.freeze

    # Parsed configuration and model metadata catalog.
    attr_reader :configuration, :catalog

    # Builds a resolver from explicit collaborators or a LittleGhost YAML
    # +directory+. With neither, conventional credentials select GPT-5.6 Luna.
    def initialize(configuration: nil, directory: nil, provider_registry: ProviderRegistry.new,
      catalog: nil, catalog_sources: [], provider_adapters: {}, credential_resolver: nil)
      @configuration = configuration || (directory && Models::Configuration.new(directory:))
      @providers = @configuration&.providers || {}
      @profiles = @configuration&.models || {}
      @default_model = @configuration&.default_model || "default"
      @provider_registry = provider_adapters.empty? ? provider_registry : ProviderRegistry.new(adapters: provider_adapters)
      @credential_resolver = credential_resolver
      configure_zero_default unless @configuration
      sources = catalog_sources.empty? ? built_in_catalog_sources : catalog_sources
      @catalog = catalog || Models::Catalog.new(
        overrides: @configuration&.model_overrides || {},
        sources:
      )
    end

    # Logical role used when an agent does not declare one.
    attr_reader :default_model

    # Resolves a logical role or canonical target into an executable Model.
    def resolve(name, invocation: nil, override: nil, run: nil, context: nil, profiles: nil, **options)
      role = name.to_s
      base = role.include?(":") ? {target: role, settings: {}, request: {}} : resolved_role(role)
      invocation_configuration = invocation ? (invocation[:model_configuration] || {}) : {}
      invocation_profiles = profiles || invocation_configuration["profiles"] || invocation_configuration[:profiles] || {}
      override_names(role).each { |profile| base = merge(base, invocation_profiles[profile] || invocation_profiles[profile.to_sym]) }
      base = merge(base, override)
      target = Models::Target.parse(base.fetch(:target))
      provider_config = @providers.fetch(target.provider) do
        raise ConfigurationError, "Model target references unknown provider #{target.provider}"
      end
      provider_config = provider_config.merge(resolved_credentials(target.provider, provider_config)) if @credential_resolver
      details = details_for(target, base[:details])
      adapter = provider_config.fetch("adapter")
      provider = @provider_registry.build(
        adapter:,
        model: target.model_id,
        configuration: provider_config,
        request: base.fetch(:request),
        role:,
        settings: base.fetch(:settings),
        details:,
        invocation:,
        context: context || run,
        **options
      )
      Model.new(provider:, target:, settings: base.fetch(:settings), details:, role:)
    end

    # Returns normalized metadata for +target+ without constructing a provider.
    def details(target) = catalog.details(target)
    # Refreshes configured metadata sources, retaining stale data on failure.
    def refresh!(target: nil) = catalog.refresh!(target:)

    private

    def resolved_credentials(provider, configuration)
      values = @credential_resolver.call(
        provider:,
        adapter: configuration.fetch("adapter"),
        configuration: configuration.dup.freeze
      )
      raise CredentialError, "Credential resolver for #{provider} must return a mapping" unless values.is_a?(Hash)

      values.to_h { |key, value| [key.to_s, value] }
    end

    def details_for(target, snapshot)
      return catalog.details(target) unless snapshot

      values = snapshot.to_h.transform_keys(&:to_sym)
      snapshot_target = Models::Target.parse(values.delete(:target) || target)
      raise ConfigurationError, "Model details target must match #{target}" unless snapshot_target == target

      Models::Details.new(
        target:,
        attributes: values.except(:provenance, :observed_at),
        provenance: values[:provenance] || {},
        observed_at: values[:observed_at]
      )
    end

    def built_in_catalog_sources
      adapters = @providers.to_h { |name, values| [name, values["adapter"].to_s] }
      sources = [Models::Catalog::ModelsDevSource.new(provider_adapters: adapters)]
      @providers.each do |name, values|
        case values["adapter"].to_s
        when "openrouter"
          sources << Providers::OpenRouter::CatalogSource.new(provider: name, api_key: values["api_key"])
        when "anthropic"
          sources << Providers::Anthropic::CatalogSource.new(provider: name, api_key: values["api_key"])
        when "gemini"
          sources << Providers::Gemini::CatalogSource.new(provider: name, api_key: values["api_key"])
        when "bedrock"
          resolver = values["credential_resolver"] || Providers::Bedrock::CredentialResolver.new
          region = values["region"] || (resolver.region if resolver.is_a?(Providers::Bedrock::CredentialResolver))
          sources << Providers::Bedrock::CatalogSource.new(provider: name, region:, credential_resolver: resolver) if region
        end
      end
      sources
    end

    def configure_zero_default
      variable, provider = DEFAULT_CREDENTIALS.find { |key, _provider| !ENV[key].to_s.strip.empty? }
      if variable
        @providers = {provider => {"adapter" => provider, "api_key" => ENV.fetch(variable)}}
        @profiles = {"default" => {"target" => "#{provider}:#{DEFAULT_MODELS.fetch(provider)}"}}
      else
        @providers = {"unconfigured" => {"adapter" => "unconfigured"}}
        @profiles = {"default" => {"target" => "unconfigured:#{DEFAULT_MODELS.fetch("openai")}"}}
        missing = "No API key is configured for the default model. Set #{DEFAULT_CREDENTIALS.map(&:first).join(", ")}, or add config/little_ghost/providers.yml and models.yml."
        @provider_registry = ProviderRegistry.new(adapters: {
          "unconfigured" => ->(**) { raise CredentialError, missing }
        })
      end
    end

    def resolved_role(role)
      profile_name = profile_for(role)
      resolved_profile(profile_name)
    end

    def profile_for(role)
      parts = role.split(".")
      until parts.empty?
        name = parts.join(".")
        return name if @profiles.key?(name)
        parts.pop
      end
      raise ConfigurationError, "Unknown model profile: #{role}"
    end

    def resolved_profile(name, seen = [])
      raise ConfigurationError, "Circular model profile inheritance: #{[*seen, name].join(" -> ")}" if seen.include?(name)

      raw = @profiles.fetch(name)
      profile = normalize(raw)
      parent_name = raw["inherits"] || raw["inherit"] || raw[:inherits] || raw[:inherit]
      return profile unless parent_name

      merge(resolved_profile(parent_name.to_s, [*seen, name]), profile)
    end

    def normalize(value)
      values = value.to_h.transform_keys(&:to_sym)
      {
        target: values[:target],
        settings: values.fetch(:settings, {}).to_h.transform_keys(&:to_sym),
        request: values.fetch(:request, {}).to_h.transform_keys(&:to_sym),
        details: values[:details]
      }.compact
    end

    def merge(base, override)
      return base unless override

      values = normalize(override)
      base.merge(values).merge(
        target: values[:target] || base[:target],
        settings: base.fetch(:settings, {}).merge(values.fetch(:settings, {})),
        request: base.fetch(:request, {}).merge(values.fetch(:request, {}))
      )
    end

    def override_names(role)
      names = []
      parts = role.split(".")
      1.upto(parts.length) { |length| names << parts.first(length).join(".") }
      names
    end
  end
end
