# frozen_string_literal: true

module LittleGhost
  module Models
    # Immutable normalized facts about one physical model.
    Details = Data.define(:target, :attributes, :provenance, :observed_at) do
      def initialize(target:, attributes: {}, provenance: {}, observed_at: nil)
        normalized = attributes.to_h.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = freeze_value(value)
        end
        sources = provenance.to_h.each_with_object({}) { |(key, value), result| result[key.to_sym] = value.to_s.freeze }
        super(
          target: Target.parse(target),
          attributes: normalized.freeze,
          provenance: sources.freeze,
          observed_at:
        )
      end

      def [](name) = attributes[name.to_sym]
      def known? = !attributes.empty?
      def pricing = self[:pricing] || {}.freeze
      def input_modalities = self[:input_modalities]
      def supported_parameters = self[:supported_parameters]
      def context_window = self[:context_window] || self[:context_window_tokens]
      def max_output_tokens = self[:max_output_tokens]

      def to_h
        attributes.merge(target: target.to_s, provenance:, observed_at:)
      end

      private

      def freeze_value(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_sym, freeze_value(child)] }.freeze
        when Array
          value.map { |child| freeze_value(child) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end
    end
  end
end
