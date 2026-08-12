# frozen_string_literal: true

require "json"
require "time"

module LittleGhost
  # Resolves model facts from application overrides, refreshed data, and the
  # snapshot packaged with LittleGhost. Refresh is always explicit.
  class ModelCatalog
    SNAPSHOT_PATH = File.expand_path("model_catalog.json", __dir__)

    def initialize(overrides: {}, sources: [], snapshot_path: SNAPSHOT_PATH, clock: -> { Time.now.utc })
      @overrides = normalize_records(overrides, "application")
      @sources = Array(sources).freeze
      @snapshot = load_snapshot(snapshot_path)
      @refreshed = {}
      @clock = clock
      @mutex = Mutex.new
    end

    def details(target)
      target = ModelTarget.parse(target)
      records = [@snapshot[target.to_s], @mutex.synchronize { @refreshed[target.to_s] }, @overrides[target.to_s]].compact
      merge_details(target, records)
    end

    # Refreshes one target or all models. Failed sources leave the last good
    # catalog untouched and are returned to the caller for reporting.
    def refresh!(target: nil)
      requested = target && ModelTarget.parse(target)
      records = {}
      errors = []
      @sources.each do |source|
        values = source.refresh(target: requested)
        records.merge!(normalize_records(values, source_name(source))) { |_key, older, newer| merge_records(older, newer) }
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

    def normalize_records(values, source)
      values.to_h.each_with_object({}) do |(target, attributes), result|
        data = attributes.to_h.transform_keys(&:to_sym)
        provenance = data.delete(:provenance) || data.keys.to_h { |key| [key, source] }
        observed_at = data.delete(:observed_at)
        result[ModelTarget.parse(target).to_s] = {attributes: data, provenance:, observed_at:}
      end
    end

    def merge_details(target, records)
      merged = records.reduce({attributes: {}, provenance: {}, observed_at: nil}) { |left, right| merge_records(left, right) }
      ModelDetails.new(target:, **merged)
    end

    def merge_records(left, right)
      {
        attributes: left.fetch(:attributes, {}).merge(right.fetch(:attributes, {})),
        provenance: left.fetch(:provenance, {}).merge(right.fetch(:provenance, {})),
        observed_at: right[:observed_at] || left[:observed_at]
      }
    end

    def source_name(source) = source.respond_to?(:name) ? source.name : source.class.name
  end
end
