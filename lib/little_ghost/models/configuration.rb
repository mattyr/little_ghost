# frozen_string_literal: true

require "erb"
require "date"
require "pathname"
require "psych"

module LittleGhost
  module Models
    # Loads trusted provider connections and logical model profiles from
    # config/little_ghost/providers.yml and models.yml.
    class Configuration
      # Configuration directory, provider connections, logical profiles,
      # metadata overrides, and fallback role.
      attr_reader :directory, :providers, :models, :model_overrides, :default_model

      # Loads and validates providers.yml and models.yml from +directory+.
      def initialize(directory:)
        @directory = Pathname(directory)
        provider_path = @directory.join("providers.yml")
        model_path = @directory.join("models.yml")
        existing = [provider_path, model_path].select(&:file?)
        if existing.one?
          missing = (existing.first == provider_path) ? model_path : provider_path
          raise ConfigurationError, "Missing LittleGhost configuration file: #{missing}"
        end
        raise ConfigurationError, "LittleGhost model configuration does not exist in #{@directory}" if existing.empty?

        provider_document = read(provider_path)
        model_document = read(model_path)
        @providers = mapping(provider_document["providers"], provider_path, "providers")
        @models = mapping(model_document["models"], model_path, "models")
        @model_overrides = mapping(model_document["model_overrides"] || {}, model_path, "model_overrides")
        @default_model = (model_document["default_model"] || "default").to_s
        validate!
        freeze
      end

      # Returns whether either conventional configuration file exists.
      def self.present?(directory)
        path = Pathname(directory)
        path.join("providers.yml").file? || path.join("models.yml").file?
      end

      private

      def read(path)
        rendered = ERB.new(path.read, trim_mode: "-").result
        Psych.safe_load(rendered, permitted_classes: [Date, Time], aliases: true) || {}
      rescue Psych::Exception, NameError => error
        raise ConfigurationError, "Invalid LittleGhost configuration in #{path}: #{error.message}"
      end

      def mapping(value, path, key)
        raise ConfigurationError, "#{path}: #{key} must be a mapping" unless value.is_a?(Hash)

        value.to_h { |name, child| [name.to_s, child.to_h] }.freeze
      end

      def validate!
        providers.each do |name, config|
          raise ConfigurationError, "providers.yml: providers.#{name}.adapter is required" if config["adapter"].to_s.empty?
        end
        models.each do |name, profile|
          next if profile["inherits"] || profile["inherit"]

          target = Target.parse(profile.fetch("target") { raise ConfigurationError, "models.yml: models.#{name}.target is required" })
          unless providers.key?(target.provider)
            raise ConfigurationError, "models.yml: models.#{name}.target references unknown provider #{target.provider}"
          end
        end
        Target.parse(default_model) if default_model.include?(":")
      end
    end
  end
end
