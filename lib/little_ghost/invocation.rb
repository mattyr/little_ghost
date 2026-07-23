# frozen_string_literal: true

require "securerandom"
require "time"

module LittleGhost
  class Invocation
    DEFAULTS = {
      "history" => -> { [] },
      "settings" => -> { {} },
      "context" => -> { {} },
      "metadata" => -> { {} },
      "model_profiles" => -> { {} }
    }.freeze

    ACCESSORS = %i[
      message history settings context metadata model_profiles
      run_id invocation_id session_id actor_id
    ].freeze

    attr_reader :env

    def initialize(env = {})
      invalid!("Invocation payload must be an object") unless env.is_a?(Hash)

      @env = env.to_h { |key, value| [normalize_key(key), duplicate_value(value)] }
      DEFAULTS.each { |key, default| @env[key] = default.call unless @env.key?(key) }
      self.history = history
      self.message = message
      initialize_identifiers!
    end

    ACCESSORS.each do |name|
      define_method(name) { self[name] }
      define_method(:"#{name}=") { |value| self[name] = value } unless %i[message history].include?(name)
    end

    def [](key) = env[normalize_key(key)]

    def []=(key, value)
      normalized = normalize_key(key)
      value = normalize_message(value) if normalized == "message"
      value = Array(value).map { |message| Message.coerce(message) }.freeze if normalized == "history"
      env[normalized] = value
    end

    def fetch(key, *defaults, &block) = env.fetch(normalize_key(key), *defaults, &block)
    def dig(key, *names) = env.dig(normalize_key(key), *names)
    def key?(key) = env.key?(normalize_key(key))
    def to_h = duplicate_value(env)

    def deadline_at
      value = self[:deadline_at]
      return value if value.nil? || value.is_a?(Time)

      self[:deadline_at] = Time.iso8601(String(value))
    rescue ArgumentError, TypeError
      invalid!("deadline_at must be a valid time")
    end

    def deadline_at=(value)
      self[:deadline_at] = value
    end

    def message=(value)
      self[:message] = value
    end

    def history=(value)
      self[:history] = value
    end

    def method_missing(name, *arguments)
      value = name.to_s
      if value.end_with?("=") && arguments.length == 1
        return self[value.delete_suffix("=")] = arguments.first
      end
      return self[value] if arguments.empty? && key?(value)

      super
    end

    def respond_to_missing?(name, include_private = false)
      value = name.to_s
      value.end_with?("=") || key?(value) || super
    end

    private

    def initialize_identifiers!
      self.run_id = generated_id if blank?(run_id)
      self.invocation_id = run_id if blank?(invocation_id)
      self.session_id = run_id if blank?(session_id)
    end

    def generated_id = SecureRandom.uuid
    def blank?(value) = value.nil? || (value.respond_to?(:empty?) && value.empty?)

    def normalize_key(key)
      key.to_s
    rescue
      invalid!("Invocation keys must be strings or symbols")
    end

    def duplicate_value(value)
      case value
      when Hash then value.to_h { |key, child| [normalize_key(key), duplicate_value(child)] }
      when Array then value.map { |child| duplicate_value(child) }
      when String then value.dup
      else value.dup
      end
    rescue TypeError
      value
    end

    def normalize_message(value)
      invalid!("Invocation requires a message") if blank?(value)

      return value if value.is_a?(Message)
      return Message.coerce(value) if value.is_a?(Hash)

      Message.new(role: :user, content: value)
    rescue ArgumentError => error
      invalid!(error.message)
    end

    def invalid!(message)
      raise InvocationError, message
    end
  end
end
