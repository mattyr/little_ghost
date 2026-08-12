# frozen_string_literal: true

require "securerandom"
require "time"

module LittleGhost
  # Carry one application request into an agent run.
  # An invocation keeps framework fields and application-specific context in one
  # indifferent-key environment.
  #
  #   invocation = LittleGhost::Invocation.new(
  #     message: "Why is transfer 481 pending?",
  #     account_id: "account-1",
  #     metadata: {channel: "customer_support"}
  #   )
  #
  #   invocation.message.text  # => "Why is transfer 481 pending?"
  #   invocation[:account_id]  # => "account-1"
  #   invocation.account_id    # => "account-1"
  #
  # String and symbol keys address the same field. Known fields have named
  # accessors, while unknown application fields remain available through hash
  # access and dynamic readers or writers. +message+ and every +history+ entry
  # are normalized to Message objects; +deadline_at+ lazily parses ISO 8601 text.
  #
  # Missing run, invocation, and session identifiers are generated when the
  # object is built. Actor identity is never inferred: applications that use it
  # for persistence or tenant isolation must pass a value established by their
  # trusted authentication boundary. Invalid payloads, messages, keys, or
  # deadlines raise InvocationError.
  class Invocation
    DEFAULTS = {
      "history" => -> { [] },
      "settings" => -> { {} },
      "context" => -> { {} },
      "metadata" => -> { {} },
      "model_configuration" => -> { {} }
    }.freeze # :nodoc:

    ACCESSORS = %i[
      message history settings context metadata model_configuration
      run_id invocation_id session_id actor_id
    ].freeze # :nodoc:

    attr_reader :env # :nodoc:

    # Copies +env+, normalizes known framework fields, and fills missing identifiers.
    #
    # The payload must be a Hash and must contain a non-blank message.
    def initialize(env = {})
      invalid!("Invocation payload must be an object") unless env.is_a?(Hash)

      @env = env.to_h { |key, value| [normalize_key(key), duplicate_value(value)] }
      DEFAULTS.each { |key, default| @env[key] = default.call unless @env.key?(key) }
      self.history = history
      self.message = message
      initialize_identifiers!
    end

    ##
    # The normalized current Message.
    # :method: message
    # :call-seq:
    #   message() -> LittleGhost::Message

    ##
    # Frozen, normalized Messages that precede the current message.
    # :method: history
    # :call-seq:
    #   history() -> Array<LittleGhost::Message>

    ##
    # Per-request model settings merged after profile defaults. Treat these as
    # trusted application policy, not unchecked request or model input.
    # :method: settings
    # :call-seq:
    #   settings() -> Hash

    ##
    # JSON-like state made available to the agent run.
    # :method: context
    # :call-seq:
    #   context() -> Hash

    ##
    # Application metadata carried with the request.
    # :method: metadata
    # :call-seq:
    #   metadata() -> Hash

    ##
    # Trusted, versioned model configuration snapshot for this invocation.
    # :method: model_configuration
    # :call-seq:
    #   model_configuration() -> Hash

    ##
    # The caller-supplied or generated top-level run identifier.
    # :method: run_id
    # :call-seq:
    #   run_id() -> String

    ##
    # The invocation identifier, defaulting to +run_id+.
    # :method: invocation_id
    # :call-seq:
    #   invocation_id() -> String

    ##
    # The session identifier, defaulting to +run_id+.
    # :method: session_id
    # :call-seq:
    #   session_id() -> String

    ##
    # The explicit actor identifier supplied by the application.
    # :method: actor_id
    # :call-seq:
    #   actor_id() -> value

    ##
    # Replaces the trusted request-scoped model settings.
    # :method: settings=
    # :call-seq:
    #   settings=(value) -> value

    ##
    # Replaces the JSON-like agent state.
    # :method: context=
    # :call-seq:
    #   context=(value) -> value

    ##
    # Replaces the application metadata.
    # :method: metadata=
    # :call-seq:
    #   metadata=(value) -> value

    ##
    # Replaces the trusted per-request model profile overrides.
    # :method: model_configuration=
    # :call-seq:
    #   model_configuration=(value) -> value

    ##
    # Replaces the top-level run identifier.
    # :method: run_id=
    # :call-seq:
    #   run_id=(value) -> value

    ##
    # Replaces the invocation identifier.
    # :method: invocation_id=
    # :call-seq:
    #   invocation_id=(value) -> value

    ##
    # Replaces the session identifier used for persistence.
    # :method: session_id=
    # :call-seq:
    #   session_id=(value) -> value

    ##
    # Replaces the application-established actor identifier.
    # :method: actor_id=
    # :call-seq:
    #   actor_id=(value) -> value
    ACCESSORS.each do |name|
      define_method(name) { self[name] }
      define_method(:"#{name}=") { |value| self[name] = value } unless %i[message history].include?(name)
    end

    # Looks up +key+ after normalizing it to a String.
    def [](key) = env[normalize_key(key)]

    # Stores +value+ under a normalized String key.
    #
    # The +message+ and +history+ fields are normalized before storage.
    def []=(key, value)
      normalized = normalize_key(key)
      value = normalize_message(value) if normalized == "message"
      value = Array(value).map { |message| Message.coerce(message) }.freeze if normalized == "history"
      env[normalized] = value
    end

    # Fetches +key+ with the same default and block behavior as Hash#fetch.
    def fetch(key, *defaults, &block) = env.fetch(normalize_key(key), *defaults, &block)

    # Traverses the environment from normalized +key+ through +names+.
    def dig(key, *names) = env.dig(normalize_key(key), *names)

    # Whether the environment contains +key+ after normalization.
    def key?(key) = env.key?(normalize_key(key))

    # Produces a mutable copy of the invocation environment.
    #
    # Nested hashes, arrays, strings, and other duplicable values are copied.
    def to_h = duplicate_value(env)

    # The request deadline as a Time, parsing ISO 8601 text on first access.
    def deadline_at
      value = self[:deadline_at]
      return value if value.nil? || value.is_a?(Time)

      self[:deadline_at] = Time.iso8601(String(value))
    rescue ArgumentError, TypeError
      invalid!("deadline_at must be a valid time")
    end

    # Replaces the deadline; parsing is deferred until +deadline_at+ is read.
    def deadline_at=(value)
      self[:deadline_at] = value
    end

    # Replaces and normalizes the current message.
    def message=(value)
      self[:message] = value
    end

    # Replaces and freezes the normalized message history.
    def history=(value)
      self[:history] = value
    end

    def method_missing(name, *arguments) # :nodoc:
      value = name.to_s
      if value.end_with?("=") && arguments.length == 1
        return self[value.delete_suffix("=")] = arguments.first
      end
      return self[value] if arguments.empty? && key?(value)

      super
    end

    def respond_to_missing?(name, include_private = false) # :nodoc:
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
