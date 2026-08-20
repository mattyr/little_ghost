# frozen_string_literal: true

require "base64"
require "json"

module LittleGhost
  # Content gives messages a shared vocabulary for text, attachments, tool calls,
  # tool results, and model reasoning. The same blocks move between agents,
  # providers, tools, and sessions without leaking a provider's wire format.
  #
  #   block = LittleGhost::Content::Text.new(text: "Hello")
  #   LittleGhost::Content.normalize("Hello") == block # => true
  #
  # Every block serializes through
  # {Content.serialize}[rdoc-ref:LittleGhost::Content.serialize]. Binary data uses
  # strict base64 encoding in the serialized form.
  module Content
    Serializable = Module.new do # :nodoc:
      def to_h = Content.serialize(self)
      def to_json(*arguments) = JSON.generate(to_h, *arguments)
    end

    # Contains model-visible text.
    Text = Data.define(:text) { include Serializable } # :nodoc:
    # Contains binary image +data+, its MIME +media_type+, and an optional name.
    Image = Data.define(:data, :media_type, :name) do # :nodoc:
      include Serializable

      def initialize(data:, media_type:, name: nil)
        super
      end
    end
    # Contains binary document +data+, MIME +media_type+, and display +name+.
    Document = Data.define(:data, :media_type, :name) { include Serializable } # :nodoc:
    # Describes a provider-requested tool call.
    ToolUse = Data.define(:id, :name, :input) do # :nodoc:
      include Serializable

      def initialize(id:, name:, input:)
        id = String(id)
        name = String(name)
        raise ArgumentError, "tool use id is required" if id.empty?
        raise ArgumentError, "tool use name is required" if name.empty?
        raise ArgumentError, "tool use input must be an object" unless input.is_a?(Hash)

        super(id: id.to_s, name: name.to_s, input: DataMap.new(input))
      rescue TypeError
        raise ArgumentError, "tool use id and name must be strings"
      end
    end
    # Contains the result for one ToolUse. +status+ is +:success+ or +:error+.
    ToolResult = Data.define(:tool_use_id, :content, :status) do # :nodoc:
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
    # Contains provider reasoning text, a provider signature, encrypted redacted
    # bytes, or provider-specific detail objects.
    #
    # Redacted bytes are mutually exclusive with text and signatures so they can
    # round-trip without exposing or changing provider-managed content.
    Reasoning = Data.define(:text, :signature, :redacted_content, :details) do # :nodoc:
      include Serializable

      def initialize(text: "", signature: nil, redacted_content: nil, details: nil)
        text = String(text)
        signature = String(signature) if signature
        redacted_content = String(redacted_content).b if redacted_content
        if details
          unless details.is_a?(Array) && details.all? { |detail| detail.is_a?(Hash) }
            raise ArgumentError, "reasoning details must be an array of objects"
          end
        end
        if redacted_content && (!text.empty? || !signature.to_s.empty?)
          raise ArgumentError, "reasoning content cannot contain both text and redacted content"
        end

        super(
          text: text.freeze,
          signature: signature&.freeze,
          redacted_content: redacted_content&.freeze,
          details: details&.map { |detail| DataMap.new(detail) }
        )
      rescue TypeError
        raise ArgumentError, "reasoning content is invalid"
      end
    end

    # Contains model-visible text.
    class Text < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(text:) -> Text
      #
      # Wraps +text+ without copying it.

      ##
      # :attr_reader: text
      # The text shown to the model or application.
    end

    # Contains binary image data, its MIME media type, and an optional display
    # name. Content.serialize base64-encodes +data+ when the block crosses a JSON
    # boundary.
    class Image < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(data:, media_type:, name: nil) -> Image
      #
      # Wraps the supplied values without copying them.

      ##
      # :attr_reader: data
      # The original binary image bytes.

      ##
      # :attr_reader: media_type
      # The image MIME type, such as +image/png+.

      ##
      # :attr_reader: name
      # The optional filename or label used when the image is presented.
    end

    # Contains binary document data, its MIME media type, and a display name.
    # Content.serialize base64-encodes +data+ when the block crosses a JSON
    # boundary.
    class Document < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(data:, media_type:, name:) -> Document
      #
      # Wraps the supplied values without copying them.

      ##
      # :attr_reader: data
      # The original binary document bytes.

      ##
      # :attr_reader: media_type
      # The document MIME type, such as +application/pdf+.

      ##
      # :attr_reader: name
      # The filename or label presented to the model.
    end

    # Describes one tool call requested by a provider-backed model.
    class ToolUse < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(id:, name:, input:) -> ToolUse
      #
      # Requires non-empty String-compatible +id+ and +name+ values and an
      # object-shaped +input+.

      ##
      # :attr_reader: id
      # The non-empty provider call identifier used to match a ToolResult.

      ##
      # :attr_reader: name
      # The non-empty model-visible tool name.

      ##
      # :attr_reader: input
      # The object-shaped arguments supplied by the model as a DataMap.
    end

    # Carries the model-facing result for one ToolUse. A successful result uses
    # +:success+; a caller-safe failure uses +:error+.
    class ToolResult < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(tool_use_id:, content:, status:) -> ToolResult
      #
      # Requires a non-empty String-compatible +tool_use_id+ and a +status+ of
      # +:success+ or +:error+.

      ##
      # :attr_reader: tool_use_id
      # The ToolUse identifier this result answers.

      ##
      # :attr_reader: content
      # The content returned to the model.

      ##
      # :attr_reader: status
      # Either +:success+ or +:error+.
    end

    # Preserves provider reasoning without forcing every provider into one
    # representation. A value may carry visible text, a provider signature,
    # opaque redacted bytes, or provider-specific detail objects.
    #
    # Redacted bytes are mutually exclusive with text and signatures so they can
    # round-trip without exposing or changing provider-managed content.
    class Reasoning < Data # :doc:
      ##
      # :singleton-method: new
      # :call-seq:
      #   new(text: "", signature: nil, redacted_content: nil, details: nil) -> Reasoning
      #
      # +details+, when present, must be an array of Hash objects.

      ##
      # :attr_reader: text
      # Visible reasoning text, or an empty string when none is available.

      ##
      # :attr_reader: signature
      # An optional provider signature associated with +text+.

      ##
      # :attr_reader: redacted_content
      # Optional opaque bytes that only the provider should interpret.

      ##
      # :attr_reader: details
      # Optional provider-specific reasoning objects.
    end

    module_function

    # Accepts an existing block, a String, or a serialized Hash.
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

    # Reconstructs a content block from its serialized hash.
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

    # Produces the JSON-safe representation of +block+.
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
          value["details"] = block.details.map(&:to_h) if block.details
        end
      when Image
        binary("image", block.data, media_type: block.media_type).tap do |value|
          value["name"] = block.name if block.name
        end
      when Document
        binary("document", block.data, media_type: block.media_type, name: block.name)
      when ToolUse
        {"type" => "tool_use", "id" => block.id, "name" => block.name, "input" => block.input.to_h}
      when ToolResult
        {
          "type" => "tool_result", "tool_use_id" => block.tool_use_id,
          "content" => serialize_tool_result_content(block.content), "status" => block.status.to_s
        }
      else
        raise ArgumentError, "Unsupported content block: #{block.class}"
      end
    end

    def binary(type, data, **attributes) # :nodoc:
      {"type" => type, "data" => Base64.strict_encode64(data), "encoding" => "base64"}
        .merge(attributes.transform_keys(&:to_s))
    end

    def serialize_tool_result_content(content) # :nodoc:
      return content unless content.is_a?(Array)

      content.map { |block| block.respond_to?(:to_h) ? block.to_h : block }
    end
  end
end
