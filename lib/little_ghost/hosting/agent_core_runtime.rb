# frozen_string_literal: true

require "json"
require "logger"

module LittleGhost
  module Hosting
    class AgentCoreRuntime
      DEFAULT_MAX_REQUEST_BYTES = 1_000_000

      def initialize(logger: Logger.new($stderr), max_request_bytes: DEFAULT_MAX_REQUEST_BYTES,
        max_pending_invocations: nil)
        @logger = logger
        @max_request_bytes = positive_integer(max_request_bytes, :max_request_bytes)
        @max_pending_invocations = optional_positive_integer(max_pending_invocations, :max_pending_invocations)
        @tasks = []
        @pending = 0
        @cleanup_error = nil
        @mutex = Mutex.new
      end

      def call(environment)
        method = environment.fetch("REQUEST_METHOD")
        path = environment.fetch("PATH_INFO")
        return ping if method == "GET" && path == "/ping"
        return invoke(environment) if method == "POST" && path == "/invocations"

        json_response(404, error_response(status: 404, message: "Not found"))
      rescue JSON::ParserError
        json_response(400, error_response(status: 400, message: "Request body must be valid JSON"))
      rescue InvocationError => error
        json_response(400, error_response(status: 400, message: error.message, error:))
      rescue RequestTooLarge
        json_response(413, error_response(status: 413, message: "Request body is too large"))
      rescue RequestInvalid
        json_response(400, error_response(status: 400, message: "Request is invalid"))
      end

      def wait
        tasks = @mutex.synchronize { @tasks.dup }
        tasks.each(&:join)
      end

      def busy?
        @mutex.synchronize do
          @tasks.reject! { |task| !task.alive? }
          !@cleanup_error.nil? || @pending.positive? || @tasks.any?
        end
      end

      protected

      def normalize(payload, environment:)
        payload
      end

      def perform(_invocation, environment:)
        raise NotImplementedError, "#{self.class} must implement #perform"
      end

      def accepted_response(_invocation)
        {status: "running"}
      end

      def error_response(status:, message:, error: nil)
        value = error.respond_to?(:errors) ? error.errors : message
        {error: value}
      end

      private

      def ping
        json_response(200, status: busy? ? "HealthyBusy" : "Healthy")
      end

      def invoke(environment)
        content_length = Integer(environment["CONTENT_LENGTH"], exception: false)
        raise RequestTooLarge if content_length && content_length > @max_request_bytes
        unless acquire_admission
          return json_response(429, error_response(status: 429, message: "Invocation capacity reached"))
        end

        begin
          body = environment.fetch("rack.input").read(@max_request_bytes + 1)
          raise RequestTooLarge if body.bytesize > @max_request_bytes

          request_environment = snapshot_environment(environment)
          invocation = normalize_payload(JSON.parse(body), request_environment)
          accepted = json_response(202, accepted_response(invocation))
          @mutex.synchronize do
            task = Thread.new do
              perform(invocation, environment: request_environment)
            rescue CleanupError => error
              @mutex.synchronize { @cleanup_error ||= error }
              @logger.error("little_ghost AgentCore Runtime invocation cleanup failed: #{error.class}")
            rescue => error
              @logger.error("little_ghost AgentCore Runtime invocation failed: #{error.class}")
            ensure
              release_admission(Thread.current)
            end
            @tasks << task
          end
          admitted = true
          accepted
        ensure
          release_admission unless admitted
        end
      end

      def normalize_payload(payload, environment)
        normalize(payload, environment:)
      rescue InvocationError
        raise
      rescue => error
        raise RequestInvalid if error.is_a?(ArgumentError)

        raise
      end

      def snapshot_environment(environment)
        environment.each_with_object({}) do |(key, value), snapshot|
          next unless key.is_a?(String)
          next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

          snapshot[key.dup.freeze] = value.is_a?(String) ? value.dup.freeze : value
        end.freeze
      end

      def release_admission(task = nil)
        @mutex.synchronize do
          @pending -= 1
          @tasks.delete(task) if task
        end
      end

      def acquire_admission
        @mutex.synchronize do
          @tasks.reject! { |candidate| !candidate.alive? }
          return false if @cleanup_error
          return false if @max_pending_invocations && @pending >= @max_pending_invocations

          @pending += 1
          true
        end
      end

      def json_response(status, body)
        encoded = JSON.generate(body)
        [status, {"content-type" => "application/json", "content-length" => encoded.bytesize.to_s}, [encoded]]
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end

      def optional_positive_integer(value, name)
        value.nil? ? nil : positive_integer(value, name)
      end

      RequestTooLarge = Class.new(StandardError)
      RequestInvalid = Class.new(StandardError)
    end
  end
end
