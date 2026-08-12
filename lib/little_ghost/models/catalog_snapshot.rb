# frozen_string_literal: true

require "json"

module LittleGhost
  module Models
    # Generates the deterministic provider-filtered catalog packaged in the gem.
    module CatalogSnapshot # :nodoc:
      NAMESPACES = {
        "amazon-bedrock" => "bedrock", "anthropic" => "anthropic", "google" => "gemini",
        "google-vertex" => "vertex_ai", "openai" => "openai", "openrouter" => "openrouter"
      }.freeze

      def self.generate(document)
        result = {}
        NAMESPACES.sort.each do |namespace, provider|
          document.fetch(namespace).fetch("models").sort.each do |model_id, value|
            attributes = normalize(value)
            attributes["provenance"] = attributes.keys.reject { |key| key == "observed_at" }.to_h { |key| [key, "bundled:models.dev"] }
            result["#{provider}:#{model_id}"] = attributes
          end
        end
        JSON.pretty_generate(result) + "\n"
      end

      def self.normalize(value)
        parameters = []
        parameters << "tools" if value["tool_call"]
        parameters << "structured_outputs" if value["structured_output"]
        parameters << "temperature" if value["temperature"]
        parameters << "reasoning" if value["reasoning"]
        {
          "context_window" => value.dig("limit", "context"),
          "max_output_tokens" => value.dig("limit", "output"),
          "input_modalities" => value.dig("modalities", "input"),
          "output_modalities" => value.dig("modalities", "output"),
          "supported_parameters" => parameters.empty? ? nil : parameters,
          "pricing" => value["cost"],
          "observed_at" => value["last_updated"] || value["release_date"]
        }.compact
      end
    end
  end
end
