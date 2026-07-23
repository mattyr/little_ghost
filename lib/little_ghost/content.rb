# frozen_string_literal: true

require "base64"
require "json"

module LittleGhost
  module Content
    Serializable = Module.new do
      def to_h = Content.serialize(self)
      def to_json(*arguments) = JSON.generate(to_h, *arguments)
    end

    Text = Data.define(:text) { include Serializable }
    Image = Data.define(:data, :media_type) { include Serializable }
    Document = Data.define(:data, :media_type, :name) { include Serializable }
    ToolUse = Data.define(:id, :name, :input) do
      include Serializable

      def initialize(id:, name:, input:)
        id = String(id)
        name = String(name)
        raise ArgumentError, "tool use id is required" if id.empty?
        raise ArgumentError, "tool use name is required" if name.empty?
        raise ArgumentError, "tool use input must be an object" unless input.is_a?(Hash)

        super(id: id.freeze, name: name.freeze, input: Support.immutable(input))
      rescue TypeError
        raise ArgumentError, "tool use id and name must be strings"
      end
    end
    ToolResult = Data.define(:tool_use_id, :content, :status) do
      include Serializable

      def initialize(tool_use_id:, content:, status:)
        tool_use_id = String(tool_use_id)
        status = status.to_sym
        raise ArgumentError, "tool result id is required" if tool_use_id.empty?
        raise ArgumentError, "tool result status must be success or error" unless %i[success error].include?(status)

        super(tool_use_id: tool_use_id.freeze, content:, status:)
      rescue TypeError, NoMethodError
        raise ArgumentError, "tool result id and status are invalid"
      end
    end
    Reasoning = Data.define(:text, :signature, :redacted_content, :details) do
      include Serializable

      def initialize(text: "", signature: nil, redacted_content: nil, details: nil)
        text = String(text)
        signature = String(signature) if signature
        redacted_content = String(redacted_content).b if redacted_content
        if details
          unless details.is_a?(Array) && details.all? { |detail| detail.is_a?(Hash) }
            raise ArgumentError, "reasoning details must be an array of objects"
          end
          details = Support.immutable(details)
        end
        if redacted_content && (!text.empty? || !signature.to_s.empty?)
          raise ArgumentError, "reasoning content cannot contain both text and redacted content"
        end

        super(
          text: text.freeze,
          signature: signature&.freeze,
          redacted_content: redacted_content&.freeze,
          details:
        )
      rescue TypeError
        raise ArgumentError, "reasoning content is invalid"
      end
    end

    module_function

    def normalize(value)
      case value
      when Text, Image, Document, ToolUse, ToolResult, Reasoning
        value
      when String
        Text.new(text: value)
      when Hash
        from_hash(value)
      else
        raise ArgumentError, "Unsupported content block: #{value.class}"
      end
    end

    def from_hash(value)
      hash = value.transform_keys(&:to_sym)
      type = hash.delete(:type)&.to_sym
      encoding = hash.delete(:encoding)
      if encoding.to_s == "base64"
        encoded = hash.delete(:data)
        raise ArgumentError, "base64 data is required" unless encoded.is_a?(String)

        decoded = Base64.strict_decode64(encoded)
        if type == :reasoning
          hash[:redacted_content] = decoded
        else
          hash[:data] = decoded
        end
      end
      if type == :tool_result
        hash[:status] = hash[:status].to_sym if hash[:status]
        if hash[:content].is_a?(Array)
          hash[:content] = hash[:content].map do |block|
            if block.is_a?(Hash) && (block.key?(:type) || block.key?("type"))
              normalize(block)
            else
              block
            end
          end
        end
      end
      klass = {
        text: Text,
        image: Image,
        document: Document,
        tool_use: ToolUse,
        tool_result: ToolResult,
        reasoning: Reasoning
      }.fetch(type) { raise ArgumentError, "Unsupported content type: #{type.inspect}" }
      klass.new(**hash)
    rescue ArgumentError, KeyError => error
      raise ArgumentError, "Invalid #{type || "content"} block: #{error.message}"
    end

    def serialize(block)
      case block
      when Text then {"type" => "text", "text" => block.text}
      when Reasoning
        {"type" => "reasoning", "text" => block.text}.tap do |value|
          value["signature"] = block.signature if block.signature
          if block.redacted_content
            value["data"] = Base64.strict_encode64(block.redacted_content)
            value["encoding"] = "base64"
          end
          value["details"] = block.details if block.details
        end
      when Image
        binary("image", block.data, media_type: block.media_type)
      when Document
        binary("document", block.data, media_type: block.media_type, name: block.name)
      when ToolUse
        {"type" => "tool_use", "id" => block.id, "name" => block.name, "input" => block.input}
      when ToolResult
        {
          "type" => "tool_result", "tool_use_id" => block.tool_use_id,
          "content" => serialize_tool_result_content(block.content), "status" => block.status.to_s
        }
      else
        raise ArgumentError, "Unsupported content block: #{block.class}"
      end
    end

    def binary(type, data, **attributes)
      {"type" => type, "data" => Base64.strict_encode64(data), "encoding" => "base64"}
        .merge(attributes.transform_keys(&:to_s))
    end

    def serialize_tool_result_content(content)
      return content unless content.is_a?(Array)

      content.map { |block| block.respond_to?(:to_h) ? block.to_h : block }
    end
  end
end
