# frozen_string_literal: true

require "json"

module LittleGhost
  module Support
    # ContentCapture lets an application opt selected diagnostic content into
    # telemetry after redaction and scrubbing. Capture stays off until an
    # application installs an enabled policy.
    #
    #   policy = LittleGhost::Support::ContentCapture.new(
    #     enabled: true,
    #     max_bytes: 16_384,
    #     redactions: [ENV.fetch("API_TOKEN")]
    #   )
    #   LittleGhost::Instrumentation.capture_content(policy)
    #
    # === Choose captured data
    #
    # Enabling capture may place model input, output, tool definitions, and
    # exception details into telemetry. Redaction and a custom scrubber reduce
    # accidental disclosure but cannot recognize every sensitive value. Configure
    # one capture policy per process and apply exporter-side controls as well.
    class ContentCapture
      CaptureLimitExceeded = Class.new(StandardError) # :nodoc:

      # Creates a policy that never captures diagnostics.
      def self.disabled = new(enabled: false)

      # Configures a policy. +max_bytes+ is applied per captured attribute and
      # +scrubber+ receives already redacted values.
      def initialize(enabled: false, max_bytes: nil, scrubber: nil, redactions: [])
        @enabled = enabled == true
        @max_bytes = Integer(max_bytes) if max_bytes
        @scrubber = scrubber
        @redactor = Redactor.new(redactions:, stringify_keys: true)
        raise ArgumentError, "max_bytes must be at least 64" if @max_bytes && @max_bytes < 64
        raise ArgumentError, "scrubber must be callable" if @scrubber && !@scrubber.respond_to?(:call)
      end

      # Produces scrubbed, JSON-encoded diagnostic attributes selected from
      # +values+, or an empty hash when disabled.
      def capture(values)
        return {} unless @enabled && values.is_a?(Hash)

        values.each_with_object({}) do |(key, value), captured|
          next unless %i[input output exception tool_definitions].include?(key.to_sym)

          captured[:"diagnostic_#{key}"] = if key.to_sym == :tool_definitions
            capture_tool_definitions(value)
          else
            value = structured_output(value) if key.to_sym == :output
            scrubbed = scrub(value)
            scrubbed = scrub(@scrubber.call(scrubbed)) if @scrubber
            truncate(JSON.generate(scrubbed))
          end
        rescue JSON::GeneratorError, Encoding::UndefinedConversionError
          captured[:"diagnostic_#{key}"] = JSON.generate("[UNSERIALIZABLE]")
        end
      end

      private

      def capture_tool_definitions(value)
        unless @max_bytes
          scrubbed = scrub(value)
          scrubbed = scrub(@scrubber.call(scrubbed)) if @scrubber
          return JSON.generate(scrubbed)
        end

        remaining = [@max_bytes - 32, 1].max
        scrubbed = bounded_scrub(value, remaining:)
        scrubbed = bounded_scrub(@scrubber.call(scrubbed), remaining:) if @scrubber
        encoded = JSON.generate(scrubbed)
        return encoded if encoded.bytesize <= @max_bytes

        JSON.generate("truncated" => true)
      rescue CaptureLimitExceeded
        JSON.generate("truncated" => true)
      end

      def bounded_scrub(value, remaining:, key: nil)
        return consume("[REDACTED]", remaining:) if key && @redactor.sensitive_key?(key)

        case value
        when Hash
          result = {}
          value.each do |child_key, child|
            key_text = consume(child_key.to_s, remaining:)
            remaining -= key_text.bytesize + 4
            result[key_text] = bounded_scrub(child, remaining:, key: child_key)
            remaining -= JSON.generate(result.fetch(key_text)).bytesize
          end
          result
        when Array
          result = []
          value.each do |child|
            captured = bounded_scrub(child, remaining:)
            result << captured
            remaining -= JSON.generate(captured).bytesize + 1
          end
          result
        when String
          raise CaptureLimitExceeded if value.bytesize + 2 > remaining

          consume(@redactor.scrub_string(value), remaining:)
        when Symbol
          consume(value.to_s, remaining:)
        when Numeric, true, false, nil
          consume(value, remaining:)
        else
          consume(value.to_s, remaining:)
        end
      end

      def consume(value, remaining:)
        raise CaptureLimitExceeded if JSON.generate(value).bytesize > remaining

        value
      end

      def scrub(value, key = nil)
        @redactor.call(value, key:)
      end

      def structured_output(value)
        return value unless value.is_a?(String)

        parsed = JSON.parse(value)
        (parsed.is_a?(Hash) || parsed.is_a?(Array)) ? parsed : value
      rescue JSON::ParserError
        value
      end

      def truncate(value)
        return value unless @max_bytes && value.bytesize > @max_bytes

        preview_bytes = [@max_bytes - 64, 1].max
        preview = value.byteslice(0, preview_bytes).to_s.force_encoding(Encoding::UTF_8).scrub
        encoded = JSON.generate("truncated" => true, "preview" => preview)
        while encoded.bytesize > @max_bytes && preview_bytes > 1
          preview_bytes = [preview_bytes / 2, 1].max
          preview = value.byteslice(0, preview_bytes).to_s.force_encoding(Encoding::UTF_8).scrub
          encoded = JSON.generate("truncated" => true, "preview" => preview)
        end
        encoded
      end
    end
  end
end
