# frozen_string_literal: true

require "json"

module LittleGhost
  module CodeMode
    class Javascript::Catalog < CodeMode::Catalog
      IDENTIFIER_CHARACTER = /[^A-Za-z0-9_$]/
      RESERVED_NAMES = %w[exec wait].freeze

      def initialize(specifications)
        super(specifications, normalize: method(:normalize), reserved: RESERVED_NAMES)
      end

      def host_definitions
        @host_definitions ||= @definitions.map do |definition|
          definition.slice("name", "description", "input_schema").freeze
        end.freeze
      end

      def declarations
        body = @definitions.map do |definition|
          description = TypeScript.comment(definition.fetch("description"))
          signature = "#{definition.fetch("name")}(args: " \
            "#{TypeScript.render(definition.fetch("input_schema"))}): Promise<unknown>;"
          [description, signature].compact.join("\n")
        end.join("\n")
        "declare const tools: {\n#{TypeScript.indent(body)}\n};"
      end

      def self.normalize(name)
        normalized = name.to_s.gsub(IDENTIFIER_CHARACTER, "_")
        normalized = "_#{normalized}" unless normalized.match?(/\A[A-Za-z_$]/)
        normalized = "_then" if normalized == "then"
        normalized
      end

      def normalize(name) = self.class.normalize(name)

      module TypeScript
        module_function

        def render(schema)
          schema = schema.to_h.transform_keys(&:to_s)
          return JSON.generate(schema.fetch("const")) if schema.key?("const")
          return schema.fetch("enum").map { |value| JSON.generate(value) }.join(" | ") if schema["enum"]

          alternatives = schema["anyOf"] || schema["oneOf"]
          return alternatives.map { |child| render(child) }.join(" | ") if alternatives
          if schema["allOf"]
            return schema.fetch("allOf").map do |child|
              value = render(child)
              value.include?(" | ") ? "(#{value})" : value
            end.join(" & ")
          end

          types = Array(schema["type"])
          return types.map { |type| render(schema.merge("type" => type)) }.uniq.join(" | ") if types.length > 1

          case types.first
          when "object" then object(schema)
          when "array" then array(schema)
          when "string" then "string"
          when "integer", "number" then "number"
          when "boolean" then "boolean"
          when "null" then "null"
          else
            schema.key?("properties") ? object(schema) : "unknown"
          end
        end

        def object(schema)
          required = Array(schema["required"])
          properties = schema.fetch("properties", {}).map do |name, child|
            property = identifier(name) ? name : JSON.generate(name)
            description = comment(child.to_h["description"] || child.to_h[:description])
            optional = "?" unless required.include?(name.to_s)
            line = "#{property}#{optional}: #{render(child)};"
            [description, line].compact.join("\n")
          end
          additional = schema["additionalProperties"]
          if additional == true
            properties << "[key: string]: unknown;"
          elsif additional.is_a?(Hash)
            properties << "[key: string]: #{render(additional)};"
          end
          return "Record<string, never>" if properties.empty? && additional == false
          return "Record<string, unknown>" if properties.empty?

          "{\n#{indent(properties.join("\n"))}\n}"
        end

        def array(schema)
          items = schema["items"]
          return "unknown[]" unless items
          return "[#{items.map { |child| render(child) }.join(", ")}]" if items.is_a?(Array)

          "Array<#{render(items)}>"
        end

        def comment(value)
          return if value.to_s.empty?

          sanitized = value.to_s.gsub("*/", "*\\/").gsub(/\s+/, " ").strip
          "/** #{sanitized} */"
        end

        def indent(value)
          value.lines.map { |line| "  #{line}" }.join
        end

        def identifier(value)
          value.to_s.match?(/\A[A-Za-z_$][A-Za-z0-9_$]*\z/)
        end
      end
    end
  end
end
