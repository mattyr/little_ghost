# frozen_string_literal: true

module LittleGhost
  class ModelRegistry
    def initialize
      @providers = {}
      @profiles = {}
    end

    def provider(name, callable = nil, &factory)
      @providers[name.to_sym] = factory || callable || raise(ArgumentError, "provider factory is required")
      self
    end

    def profile(name, provider: nil, model: nil, settings: {}, metadata: {}, inherit: nil)
      @profiles[name.to_s] = {
        provider: provider&.to_sym,
        model: model&.to_s,
        settings: settings.to_h.transform_keys(&:to_sym),
        metadata: metadata.to_h,
        inherit: inherit&.to_s
      }
      self
    end

    def resolve(name, invocation: nil, override: nil, run: nil, context: nil, **options)
      role = name.to_s
      profile_name = profile_for(role)
      configuration = resolved_profile(profile_name)
      override_profiles(profile_name, role).each do |profile|
        configuration = merge(configuration, profile_override(invocation, profile))
      end
      configuration = merge(configuration, override)
      provider_name = configuration[:provider]
      model_id = configuration[:model]
      raise ConfigurationError, "Model profile #{profile_name} does not define a provider" unless provider_name
      raise ConfigurationError, "Model profile #{profile_name} does not define a model" unless model_id

      factory = @providers.fetch(provider_name) do
        raise ConfigurationError, "No provider is registered for #{provider_name}"
      end
      provider = factory.call(
        model: model_id,
        role:,
        settings: configuration.fetch(:settings),
        metadata: configuration.fetch(:metadata),
        invocation:,
        context: context || run,
        **options
      )
      Model.new(
        provider:,
        provider_name:,
        model: model_id,
        settings: configuration.fetch(:settings),
        metadata: configuration.fetch(:metadata),
        role:
      )
    end

    private

    def merge(configuration, override)
      values = (override || {}).to_h.transform_keys(&:to_sym)
      settings = values.fetch(:settings, values.fetch(:parameters, {})).to_h.transform_keys(&:to_sym)
      configuration
        .merge(values.except(:settings, :parameters, :model_id))
        .merge(
          provider: values.key?(:provider) ? values[:provider]&.to_sym : configuration[:provider],
          model: values.fetch(:model, values.fetch(:model_id, configuration[:model])),
          settings: configuration.fetch(:settings).merge(settings),
          metadata: configuration.fetch(:metadata).merge(values.fetch(:metadata, {}))
        )
    end

    def profile_for(role)
      parts = role.to_s.split(".")
      until parts.empty?
        candidate = parts.join(".")
        return candidate if @profiles.key?(candidate)

        parts.pop
      end
      raise ConfigurationError, "Unknown model profile: #{role}"
    end

    def resolved_profile(name, seen = [])
      raise ConfigurationError, "Circular model profile inheritance: #{[*seen, name].join(" -> ")}" if seen.include?(name)

      profile = @profiles.fetch(name) do
        raise ConfigurationError, "Unknown model profile: #{name}"
      end
      parent_name = profile.fetch(:inherit)
      return profile unless parent_name

      parent = resolved_profile(parent_name, [*seen, name])
      {
        provider: profile.fetch(:provider) || parent.fetch(:provider),
        model: profile.fetch(:model) || parent.fetch(:model),
        settings: parent.fetch(:settings).merge(profile.fetch(:settings)),
        metadata: parent.fetch(:metadata).merge(profile.fetch(:metadata)),
        inherit: parent_name
      }
    end

    def override_profiles(profile_name, role)
      names = []
      current = profile_name
      while current
        names.unshift(current)
        current = @profiles.fetch(current).fetch(:inherit)
      end
      names << role unless names.include?(role)
      names
    end

    def profile_override(invocation, role)
      profiles = invocation&.model_profiles || {}
      profiles[role.to_s] || {}
    end
  end
end
