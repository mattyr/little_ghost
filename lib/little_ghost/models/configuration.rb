# frozen_string_literal: true

require "erb"
require "date"
require "pathname"
require "psych"

module LittleGhost
  module Models
    # Loads trusted provider connections or logical model profiles from YAML.
    class Configuration
      class << self
        # Loads provider connections from +path+.
        def providers(path)
          document = read(path)
          Providers::Configuration.new(mapping(document["providers"], path, "providers"))
        end

        # Loads model profiles and an optional default role from +path+.
        def models(path)
          document = read(path)
          [mapping(document["models"], path, "models"), document["default_model"]&.to_s]
        end

        private

        def read(path)
          path = Pathname(path)
          rendered = ERB.new(path.read, trim_mode: "-").result
          Psych.safe_load(rendered, permitted_classes: [Date, Time], aliases: true) || {}
        rescue Psych::Exception, NameError => error
          raise ConfigurationError, "Invalid LittleGhost configuration in #{path}: #{error.message}"
        end

        def mapping(value, path, key)
          raise ConfigurationError, "#{path}: #{key} must be a mapping" unless value.is_a?(Hash)

          value.to_h { |name, child| [name.to_s, child.to_h] }.freeze
        end
      end
    end
  end
end
