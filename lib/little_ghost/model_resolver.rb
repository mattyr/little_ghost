# frozen_string_literal: true

module LittleGhost
  # Resolves logical profiles and canonical +provider:model-id+ targets into
  # executable Model objects. Subclasses may override #resolve, #details, or
  # #refresh! while preserving those public signatures.
  class ModelResolver
    DEFAULT_CREDENTIALS = [ # :nodoc:
      ["LITTLEGHOST_OPENROUTER_API_KEY", "openrouter"],
      ["LITTLEGHOST_OPENAI_API_KEY", "openai"],
      ["OPENROUTER_API_KEY", "openrouter"],
      ["OPENAI_API_KEY", "openai"]
    ].freeze
    DEFAULT_MODELS = { # :nodoc:
      "openrouter" => "openai/gpt-5.6-luna",
      "openai" => "gpt-5.6-luna"
    }.freeze

    # Provider configuration and model metadata catalog.
    attr_reader :providers, :catalog

    # Builds a resolver from explicit provider connections and profiles. With
    # neither, conventional credentials select GPT-5.6 Luna.
    def initialize(providers: nil, profiles: nil, default_model: nil, provider_registry: ProviderRegistry.new,
      catalog: nil, catalog_sources: [], provider_adapters: {}, credential_resolver: nil)
      unless providers.nil? || providers.is_a?(Providers::Configuration)
        raise ArgumentError, "providers must be a LittleGhost::Providers::Configuration"
      end

      @providers = providers
      @connections = providers&.connections || {}
      @profiles = normalize_profiles(profiles || {})
      @default_model = default_model&.to_s || "default"
      @provider_registry = provider_adapters.empty? ? provider_registry : ProviderRegistry.new(adapters: provider_adapters)
      @credential_resolver = credential_resolver
      configure_default_providers unless providers
      configure_default_profiles unless profiles
      sources = catalog_sources.empty? ? built_in_catalog_sources : catalog_sources
      @catalog = catalog || Models::Catalog.new(sources:)
    end

    # Logical role used when an agent does not declare one.
    attr_reader :default_model

    # Resolves a logical role or canonical target into an executable Model.
    # The optional +profiles+ mapping overlays trusted profiles explicitly; the
    # resolver does not read overlays from +invocation+.
    def resolve(name, invocation: nil, context: nil, profiles: nil, **options)
      role = name.to_s
      base = role.include?(":") ? {target: role, settings: {}, request: {}} : resolved_role(role)
      profile_overlays = profiles || {}
      override_names(role).each { |profile| base = merge(base, profile_overlays[profile] || profile_overlays[profile.to_sym]) }
      target = Models::Target.parse(base.fetch(:target))
      provider_config = @connections.fetch(target.provider) do
        raise ConfigurationError, "Model target references unknown provider #{target.provider}"
      end
      provider_config = provider_config.merge(resolved_credentials(target.provider, provider_config)) if @credential_resolver
      details = details_for(target, base[:details])
      settings = clamp_output_tokens(base.fetch(:settings), details)
      adapter = provider_config.fetch("adapter")
      provider = @provider_registry.build(
        adapter:,
        model: target.model_id,
        configuration: provider_config,
        request: base.fetch(:request),
        role:,
        settings:,
        details:,
        invocation:,
        context:,
        **options
      )
      Model.new(provider:, target:, settings:, details:, role:)
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
      return details(target) unless snapshot

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

    def clamp_output_tokens(settings, details)
      configured = settings[:max_tokens]
      advertised = details.max_output_tokens
      return settings unless configured && advertised

      settings.merge(max_tokens: [configured, advertised].min)
    end

    def built_in_catalog_sources
      adapters = @connections.to_h { |name, values| [name, values["adapter"].to_s] }
      sources = [Models::Catalog::ModelsDevSource.new(provider_adapters: adapters)]
      @connections.each do |name, values|
        credentials = -> { catalog_credentials(name, values) }
        case values["adapter"].to_s
        when "openrouter"
          sources << Providers::OpenRouter::CatalogSource.new(provider: name, credential_resolver: credentials)
        when "anthropic"
          sources << Providers::Anthropic::CatalogSource.new(provider: name, credential_resolver: credentials)
        when "gemini"
          sources << Providers::Gemini::CatalogSource.new(provider: name, credential_resolver: credentials)
        when "bedrock"
          resolver = values["credential_resolver"] || bedrock_credential_resolver(name, values)
          region = values["region"] || (resolver.region if resolver.is_a?(Providers::Bedrock::CredentialResolver))
          sources << Providers::Bedrock::CatalogSource.new(provider: name, region:, credential_resolver: resolver) if region
        end
      end
      sources
    end

    def catalog_credentials(provider, configuration)
      return configuration unless @credential_resolver

      configuration.merge(resolved_credentials(provider, configuration))
    end

    def bedrock_credential_resolver(provider, configuration)
      return Providers::Bedrock::CredentialResolver.new unless @credential_resolver

      fallback = Providers::Bedrock::CredentialResolver.new
      lambda do
        values = catalog_credentials(provider, configuration)
        next values["credentials"] if values["credentials"]

        access_key_id = values["access_key_id"] || values["aws_access_key_id"]
        secret_access_key = values["secret_access_key"] || values["aws_secret_access_key"]
        if access_key_id || secret_access_key
          Providers::Bedrock::Credentials.new(
            access_key_id:,
            secret_access_key:,
            session_token: values["session_token"] || values["aws_session_token"]
          )
        else
          fallback.call
        end
      end
    end

    def configure_default_providers
      variable, provider = DEFAULT_CREDENTIALS.find { |key, _provider| !ENV[key].to_s.strip.empty? }
      if variable
        @connections = {provider => {"adapter" => provider, "api_key" => ENV.fetch(variable)}}
      else
        @connections = {"unconfigured" => {"adapter" => "unconfigured"}}
        missing = "No API key is configured for the default model. Set #{DEFAULT_CREDENTIALS.map(&:first).join(", ")}, configure providers inline, or add config/little_ghost/providers.yml."
        @provider_registry = ProviderRegistry.new(adapters: {
          "unconfigured" => ->(**) { raise CredentialError, missing }
        })
      end
    end

    def configure_default_profiles
      connection, values = @connections.find { |_name, options| DEFAULT_MODELS.key?(options["adapter"].to_s) }
      @profiles = if connection
        {"default" => {"target" => "#{connection}:#{DEFAULT_MODELS.fetch(values["adapter"].to_s)}"}}
      else
        {"default" => {"target" => "unconfigured:#{DEFAULT_MODELS.fetch("openai")}"}}
      end
    end

    def resolved_role(role)
      profile_name = profile_for(role)
      resolved_profile(profile_name)
    end

    def normalize_profiles(profiles)
      raise ConfigurationError, "models must be a mapping" unless profiles.is_a?(Hash)

      profiles.to_h { |name, profile| [name.to_s, profile.to_h] }
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
      parent_name = raw["inherits"] || raw[:inherits]
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
