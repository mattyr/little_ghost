# frozen_string_literal: true

module LittleGhost
  module Support
    # Redactor removes common credential keys, known secret values, and
    # secret-shaped strings from nested diagnostic data. It returns a copy and
    # leaves the caller's value unchanged.
    #
    # Redaction is a defense-in-depth aid, not proof that arbitrary
    # sensitive content is safe to export. Applications should add known secret
    # values and send telemetry only to the intended destination.
    class Redactor
      SENSITIVE_KEY = /(authorization|api[_-]?key|credential|password|secret|(?:^|[_-])token(?:$|[_-])|cookie|private[_-]?key)/i # :nodoc:
      SECRET_PATTERNS = [
        /\bBearer\s+[A-Za-z0-9._~+\/-]+=*/i,
        /\b(?:gh[opusr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/,
        /\bAKIA[A-Z0-9]{16}\b/,
        /\b(?:sk|pk)-[A-Za-z0-9_-]{20,}\b/
      ].freeze # :nodoc:

      # Adds literal secrets to the built-in patterns. Values shorter than
      # eight characters are ignored to avoid over-redaction.
      def initialize(redactions: [], stringify_keys: false)
        @redactions = Array(redactions).map(&:to_s).reject { |value| value.length < 8 }.uniq.freeze
        @stringify_keys = stringify_keys
      end

      # Produces a redacted copy of +value+.
      def call(value, key: nil)
        return "[REDACTED]" if key && sensitive_key?(key)

        case value
        when Hash
          value.to_h do |child_key, child|
            output_key = @stringify_keys ? child_key.to_s : child_key
            [output_key, call(child, key: child_key)]
          end
        when Array
          value.map { |child| call(child) }
        when String
          scrub_string(value)
        else
          value
        end
      end

      # Checks whether +key+ matches a credential-like name.
      def sensitive_key?(key)
        SENSITIVE_KEY.match?(normalize_key(key))
      end

      # Normalizes invalid UTF-8 and replaces configured and common secrets.
      def scrub_string(value)
        normalized = value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        text = @redactions.reduce(normalized) { |current, secret| current.gsub(secret, "[REDACTED]") }
        SECRET_PATTERNS.reduce(text) { |current, pattern| current.gsub(pattern, "[REDACTED]") }
      end

      private

      def normalize_key(key)
        key.to_s.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").downcase
      end
    end
  end
end
