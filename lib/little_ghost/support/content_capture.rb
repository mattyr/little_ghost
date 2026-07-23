# frozen_string_literal: true

require "json"

module LittleGhost
  module Support
    class ContentCapture
      CaptureLimitExceeded = Class.new(StandardError)

      SENSITIVE_KEY = /(authorization|api[_-]?key|credential|password|secret|(?:^|[_-])token(?:$|[_-])|cookie|private[_-]?key)/i
      SECRET_PATTERNS = [
        /\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
        /\b(?:gh[opusr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/,
        /\bAKIA[A-Z0-9]{16}\b/,
        /\b(?:sk|pk)-[A-Za-z0-9_-]{20,}\b/
      ].freeze

      def self.disabled = new(enabled: false)

      def initialize(enabled: false, max_bytes: 64_000, scrubber: nil, redactions: [])
        @enabled = enabled == true
        @max_bytes = Integer(max_bytes)
        @scrubber = scrubber
        @redactions = Array(redactions).map(&:to_s).reject { |value| value.length < 8 }.uniq.freeze
        raise ArgumentError, "max_bytes must be at least 64" if @max_bytes < 64
        raise ArgumentError, "scrubber must be callable" if @scrubber && !@scrubber.respond_to?(:call)
      end

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
        normalized_key = key.to_s.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
        return consume("[REDACTED]", remaining:) if key && SENSITIVE_KEY.match?(normalized_key)

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

          consume(scrub_string(value), remaining:)
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
        normalized_key = key.to_s.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
        return "[REDACTED]" if key && SENSITIVE_KEY.match?(normalized_key)

        case value
        when Hash
          value.to_h { |child_key, child| [child_key.to_s, scrub(child, child_key)] }
        when Array
          value.map { |child| scrub(child) }
        when String
          scrub_string(value)
        when Symbol
          value.to_s
        when Numeric, true, false, nil
          value
        else
          value.to_s
        end
      end

      def scrub_string(value)
        text = @redactions.reduce(value.dup) { |current, secret| current.gsub(secret, "[REDACTED]") }
        SECRET_PATTERNS.reduce(text) { |current, pattern| current.gsub(pattern, "[REDACTED]") }
      end

      def structured_output(value)
        return value unless value.is_a?(String)

        parsed = JSON.parse(value)
        (parsed.is_a?(Hash) || parsed.is_a?(Array)) ? parsed : value
      rescue JSON::ParserError
        value
      end

      def truncate(value)
        return value if value.bytesize <= @max_bytes

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
