# frozen_string_literal: true

require "json"
require "time"

module LittleGhost
  # Immutable model identities, metadata, configuration readers, and catalogs.
  module Models
    # Resolves model facts from refreshed data and the snapshot packaged with
    # LittleGhost. Refresh is always explicit.
    class Catalog
      ARRAY_ATTRIBUTES = %i[input_modalities output_modalities supported_parameters].freeze # :nodoc:

      # Path to the offline model metadata snapshot packaged with the gem.
      SNAPSHOT_PATH = File.expand_path("../data/model_catalog.json", __dir__)

      # Builds a layered catalog from bundled and refreshed facts.
      def initialize(sources: [], snapshot_path: SNAPSHOT_PATH, clock: -> { Time.now.utc })
        @sources = Array(sources).freeze
        @snapshot = load_snapshot(snapshot_path)
        @refreshed = {}
        @clock = clock
        @mutex = Mutex.new
      end

      # Returns immutable normalized details for +target+.
      def details(target)
        target = Target.parse(target)
        records = [@snapshot[target.to_s], @mutex.synchronize { @refreshed[target.to_s] }].compact
        merge_details(target, records)
      end

      # Refreshes one target or all models. Failed sources leave the last good
      # catalog untouched and are returned to the caller for reporting.
      def refresh!(target: nil)
        requested = target && Target.parse(target)
        records = {}
        errors = []
        @sources.each do |source|
          values = source.refresh(target: requested)
          normalized = normalize_records(
            values,
            source.name,
            attribute_merge_strategies: source.attribute_merge_strategies
          )
          records = records.merge(normalized) { |_key, older, newer| merge_records(older, newer) }
        rescue => error
          errors << error
        end
        @mutex.synchronize { @refreshed = @refreshed.merge(records) { |_key, older, newer| merge_records(older, newer) } } unless records.empty?
        {updated: records.keys.freeze, errors: errors.freeze}.freeze
      end

      private

      def load_snapshot(path)
        return {} unless File.file?(path)

        normalize_records(JSON.parse(File.read(path)), "bundled")
      rescue JSON::ParserError => error
        raise ConfigurationError, "Bundled model catalog is invalid: #{error.message}"
      end

      def normalize_records(values, source, attribute_merge_strategies: {})
        strategies = normalize_merge_strategies(attribute_merge_strategies)
        values.to_h.each_with_object({}) do |(target, attributes), result|
          data = attributes.to_h.transform_keys(&:to_sym)
          provenance = data.delete(:provenance) || data.keys.to_h { |key| [key, source] }
          provenance = provenance.to_h { |key, value| [key.to_sym, value] }
          observed_at = data.delete(:observed_at)
          validate_array_attributes!(data)
          record_strategies = strategies.select { |attribute, _strategy| data.key?(attribute) }.freeze
          validate_strategy_values!(data, record_strategies)
          result[Target.parse(target).to_s] = {
            attributes: data,
            provenance:,
            observed_at:,
            attribute_merge_strategies: record_strategies
          }
        end
      end

      def merge_details(target, records)
        merged = records.reduce({attributes: {}, provenance: {}, observed_at: nil}) { |left, right| merge_records(left, right) }
        Details.new(
          target:,
          attributes: merged.fetch(:attributes),
          provenance: merged.fetch(:provenance),
          observed_at: merged[:observed_at]
        )
      end

      def merge_records(left, right)
        attributes = left.fetch(:attributes, {}).merge(right.fetch(:attributes, {}))
        provenance = left.fetch(:provenance, {}).merge(right.fetch(:provenance, {}))
        right_strategies = right.fetch(:attribute_merge_strategies, {})
        apply_attribute_merge_strategies!(attributes, provenance, left, right, right_strategies)
        strategies = left.fetch(:attribute_merge_strategies, {}).dup
        right.fetch(:attributes, {}).each_key { |attribute| strategies.delete(attribute) }
        strategies.merge!(right_strategies).freeze
        {
          attributes:,
          provenance:,
          observed_at: right[:observed_at] || left[:observed_at],
          attribute_merge_strategies: strategies
        }
      end

      def normalize_merge_strategies(strategies)
        strategies.to_h.each_with_object({}) do |(attribute, strategy), normalized|
          unless attribute.is_a?(String) || attribute.is_a?(Symbol)
            raise ConfigurationError, "Catalog merge strategy attributes must be strings or symbols"
          end
          unless strategy == :union || strategy == "union"
            raise ConfigurationError, "Unsupported catalog merge strategy: #{strategy}"
          end

          normalized[attribute.to_sym] = :union
        end.freeze
      end

      def apply_attribute_merge_strategies!(attributes, provenance, left, right, strategies)
        strategies.each do |attribute, strategy|
          existing = left.fetch(:attributes, {})[attribute]
          refreshed = right.fetch(:attributes, {})[attribute]
          next unless existing && refreshed

          attributes[attribute] = (existing + refreshed).uniq if strategy == :union
          previous_source = left.fetch(:provenance, {})[attribute]
          current_source = right.fetch(:provenance, {})[attribute]
          sources = [previous_source, current_source].compact.uniq
          provenance[attribute] = sources.join("+") unless sources.empty?
        end
      end

      def validate_strategy_values!(attributes, strategies)
        strategies.each_key do |attribute|
          unless attributes.fetch(attribute).is_a?(Array)
            raise ConfigurationError, "Catalog union attribute #{attribute} must be an array"
          end
        end
      end

      def validate_array_attributes!(attributes)
        ARRAY_ATTRIBUTES.each do |attribute|
          value = attributes[attribute]
          next if value.nil? || value.is_a?(Array)

          raise ConfigurationError, "Catalog attribute #{attribute} must be an array"
        end
      end
    end
  end
end
