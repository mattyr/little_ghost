# frozen_string_literal: true

module LittleGhost
  module MCP
    module ImmutableValue # :nodoc:
      module_function

      def mapping(value, field:)
        raise ProtocolError, "MCP #{field} must be an object" unless value.is_a?(Hash)

        freeze_value(DataMap.new(value))
      rescue ArgumentError => error
        raise ProtocolError, "MCP #{field} is invalid: #{error.message}"
      end

      def optional_mapping(value, field:)
        return if value.nil?

        mapping(value, field:)
      end

      def array(value, field:)
        raise ProtocolError, "MCP #{field} must be an array" unless value.is_a?(Array)

        freeze_value(DataMap.new("items" => value).fetch("items"))
      rescue ArgumentError => error
        raise ProtocolError, "MCP #{field} is invalid: #{error.message}"
      end

      def freeze_value(value)
        pending = [value]
        until pending.empty?
          current = pending.pop
          case current
          when Hash
            current.each do |key, child|
              key.freeze
              pending << child
            end
          when Array
            current.each { |child| pending << child }
          end
          current.freeze
        end
        value
      end
    end

    Definition = Data.define( # :nodoc:
      :source_name,
      :name,
      :description,
      :input_schema,
      :output_schema,
      :annotations,
      :title,
      :metadata,
      :raw
    ) do
      def initialize(source_name:, name:, description:, input_schema:, raw:, output_schema: nil,
        annotations: {}, title: nil, metadata: {})
        source_name = String(source_name)
        name = String(name)
        raise ProtocolError, "MCP tool definition must include a name" if source_name.empty?
        raise ConfigurationError, "MCP tool name cannot be empty" if name.empty?

        super(
          source_name: source_name.freeze,
          name: name.freeze,
          description: String(description).freeze,
          input_schema: ImmutableValue.mapping(input_schema, field: "tool inputSchema"),
          output_schema: ImmutableValue.optional_mapping(output_schema, field: "tool outputSchema"),
          annotations: ImmutableValue.mapping(annotations, field: "tool annotations"),
          title: title.nil? ? nil : String(title).freeze,
          metadata: ImmutableValue.mapping(metadata, field: "tool _meta"),
          raw: ImmutableValue.mapping(raw, field: "tool definition")
        )
      rescue TypeError
        raise ProtocolError, "MCP tool definition is invalid"
      end

      def [](key) = raw[key]
      def fetch(...) = raw.fetch(...)
      def dig(...) = raw.dig(...)
      def key?(key) = raw.key?(key)
    end

    # Immutable server-advertised Tool metadata. +source_name+ is always the
    # name sent back to the server; +name+ is the initially generated
    # model-facing name and may later be customized on the generated Tool class.
    class Definition < Data # :doc:
      ##
      # :attr_reader: source_name
      # The unmodified server-advertised name used for dispatch.

      ##
      # :attr_reader: name
      # The normalized, optionally prefixed initial model-facing name.

      ##
      # :attr_reader: description
      # The model-facing description, including LittleGhost's fallback when the
      # server omitted one.

      ##
      # :attr_reader: input_schema
      # The deeply frozen MCP input schema.

      ##
      # :attr_reader: output_schema
      # The optional deeply frozen MCP output schema.

      ##
      # :attr_reader: annotations
      # Deeply frozen MCP tool annotations.

      ##
      # :attr_reader: title
      # The optional human-readable MCP title.

      ##
      # :attr_reader: metadata
      # Deeply frozen MCP <tt>_meta</tt> object.

      ##
      # :attr_reader: raw
      # A deeply frozen, indifferent-access copy of the complete wire value.
      # Definition also delegates +[]+, +fetch+, +dig+, and +key?+ to this map.
    end

    Call = Data.define(:definition, :arguments, :context, :binding) do # :nodoc:
      def initialize(definition:, arguments:, context: nil, binding: Tool::Binding.new)
        raise ArgumentError, "definition must be a LittleGhost::MCP::Definition" unless definition.is_a?(Definition)

        super(
          definition:,
          arguments: ImmutableValue.mapping(arguments, field: "tool call arguments"),
          context:,
          binding:
        )
      end
    end

    # Immutable context for one MCP Tool invocation. It combines the advertised
    # Definition with a copied argument object and the run-scoped collaborators
    # used for the call.
    class Call < Data # :doc:
      ##
      # :attr_reader: definition
      # The Definition whose +source_name+ is sent to the server.

      ##
      # :attr_reader: arguments
      # Deeply frozen, indifferent-access arguments.

      ##
      # :attr_reader: context
      # The RunContext controlling cancellation, deadlines, and working state.

      ##
      # :attr_reader: binding
      # The Tool::Binding for the generated Tool instance.
    end

    Result = Data.define(:content, :structured_content, :error, :metadata, :raw) do # :nodoc:
      def initialize(content:, raw:, structured_content: nil, error: false, metadata: {})
        unless error.nil? || error == true || error == false
          raise ProtocolError, "MCP tool result isError must be boolean"
        end

        super(
          content: ImmutableValue.array(content, field: "tool result content"),
          structured_content: ImmutableValue.optional_mapping(
            structured_content,
            field: "structuredContent"
          ),
          error: !!error,
          metadata: ImmutableValue.mapping(metadata, field: "tool result _meta"),
          raw: ImmutableValue.mapping(raw, field: "tool result")
        )
      end

      def error? = error
    end

    # Immutable, fidelity-preserving MCP Tool result. The raw protocol value is
    # retained alongside normalized content and structured content so policies
    # can make application-specific decisions without reparsing model text.
    class Result < Data # :doc:
      ##
      # :attr_reader: content
      # Deeply frozen MCP content blocks.

      ##
      # :attr_reader: structured_content
      # The optional deeply frozen structured result object.

      ##
      # :attr_reader: error
      # Whether the server marked the result with <tt>isError</tt>.

      ##
      # :attr_reader: metadata
      # Deeply frozen MCP result <tt>_meta</tt>.

      ##
      # :attr_reader: raw
      # A deeply frozen copy of the complete wire result.

      ##
      # :method: error?
      # Whether the server marked the result as an error.
    end
  end
end
