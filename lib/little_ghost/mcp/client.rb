# frozen_string_literal: true

require "digest"
require "base64"
require "json"
require "json_schemer"
require "net/http"
require "uri"

module LittleGhost
  # MCP lets LittleGhost agents use tools published by Model Context Protocol
  # servers. Require +little_ghost/mcp+ to load the optional HTTP integration.
  module MCP
    # Model Context Protocol version negotiated by Client.
    PROTOCOL_VERSION = "2025-06-18"

    # HTTPTransport sends MCP JSON-RPC messages over Streamable HTTP. It applies
    # time and response-size limits and keeps the negotiated MCP session ID.
    #
    # === Connections and credentials
    #
    # HTTPS is required by default. +allow_insecure_http+ is only for a local
    # development endpoint. Scope caller-supplied
    # credential headers to the target server. Response bodies and negotiated
    # session IDs are validated before use.
    #
    # One transport instance retains one negotiated MCP session ID and sends it
    # with later requests. Use one transport and Client for one server and one
    # authenticated user or service identity; never share that pair across
    # tenants. LittleGhost does not send MCP session-termination DELETE requests,
    # so configure server-side expiry or send the cleanup request outside this
    # transport when the server requires explicit session termination.
    class HTTPTransport
      # Default upper bound for one MCP response body (10 MiB).
      DEFAULT_MAX_RESPONSE_BYTES = 10 * 1024 * 1024
      SESSION_ID_PATTERN = /\A[\x21-\x7e]{1,256}\z/ # :nodoc:

      # Configures time and response-size limits. +signer+, when
      # supplied, is called with each Net::HTTP request before it is sent.
      def initialize(url:, headers: {}, timeout: 60, signer: nil, allow_insecure_http: false,
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES)
        @uri = URI(url)
        unless %w[http https].include?(@uri.scheme) && @uri.host
          raise ConfigurationError, "MCP URL must be an HTTP(S) URL"
        end
        if @uri.scheme == "http" && !allow_insecure_http
          raise ConfigurationError, "MCP URL must use HTTPS unless allow_insecure_http is enabled"
        end

        @headers = headers.transform_keys(&:to_s).freeze
        @timeout = Float(timeout)
        raise ArgumentError, "timeout must be positive" unless @timeout.positive?

        @max_response_bytes = Integer(max_response_bytes)
        raise ArgumentError, "max_response_bytes must be positive" unless @max_response_bytes.positive?

        @signer = signer
        @session_id = nil
      end

      # Sends one JSON-RPC payload. A RunContext supplies cancellation and a
      # deadline; without it the configured timeout applies.
      def send(payload, context: nil)
        return perform_send(payload, timeout: @timeout) unless context

        response = nil
        stream = Support::InterruptibleStream.new(
          cancellation_token: context.cancellation_token,
          deadline: context.deadline
        ) do |emit|
          emit.call(perform_send(payload, timeout: context.remaining_time(@timeout)))
        end
        stream.each { |value| response = value }
        response
      end

      private

      def perform_send(payload, timeout:)
        request = Net::HTTP::Post.new(@uri)
        @headers.each { |name, value| request[name] = value }
        request["Accept"] ||= "application/json, text/event-stream"
        request["Content-Type"] ||= "application/json"
        request["MCP-Protocol-Version"] ||= PROTOCOL_VERSION
        request["Mcp-Session-Id"] = @session_id if @session_id
        request.body = JSON.generate(payload)
        @signer&.call(request)

        response = nil
        response_body = +""
        http(timeout).request(request) do |received|
          response = received
          validate_content_length!(received)
          received.read_body do |chunk|
            response_body << chunk
            raise ProtocolError, "MCP response exceeded #{@max_response_bytes} bytes" if response_body.bytesize > @max_response_bytes
          end
        end
        @session_id = validated_session_id(response["Mcp-Session-Id"]) if response["Mcp-Session-Id"]
        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
          raise ProtocolError, "MCP request failed with HTTP #{response.code}"
        end

        parse(response, response_body, payload[:id])
      rescue JSON::ParserError => error
        raise ProtocolError, "MCP returned invalid JSON: #{error.message}"
      rescue SystemCallError, SocketError, Timeout::Error => error
        raise ProviderError, "MCP transport failed: #{error.class}"
      end

      def http(timeout)
        Net::HTTP.new(@uri.host, @uri.port).tap do |client|
          client.use_ssl = @uri.scheme == "https"
          client.open_timeout = timeout
          client.read_timeout = timeout
          client.write_timeout = timeout
        end
      end

      def parse(response, body, expected_id)
        return {} if body.empty?

        if response["Content-Type"].to_s.include?("text/event-stream")
          payloads = body.scan(/^data:\s*(.+)$/).flatten.reject { |data| data == "[DONE]" }
          raise ProtocolError, "MCP event stream contained no response" if payloads.empty?

          messages = payloads.map { |payload| JSON.parse(payload) }
          messages.reverse.find { |message| expected_id.nil? || message["id"] == expected_id } || {}
        else
          JSON.parse(body)
        end
      end

      def validate_content_length!(response)
        content_length = response["Content-Length"]
        if content_length && Integer(content_length, exception: false).to_i > @max_response_bytes
          raise ProtocolError, "MCP response exceeded #{@max_response_bytes} bytes"
        end
      end

      def validated_session_id(value)
        return value if SESSION_ID_PATTERN.match?(value)

        raise ProtocolError, "MCP server returned an invalid session ID"
      end
    end

    # Client is the lower-level interface for loading tools from an MCP server.
    # Most Agents can declare a reusable Toolset instead. Use Client directly
    # when an application needs a custom transport.
    #
    #   transport = LittleGhost::MCP::HTTPTransport.new(url: "https://mcp.example/rpc")
    #   client = LittleGhost::MCP::Client.new(transport:)
    #   client.tools.map(&:tool_name) # => ["search", "fetch"]
    #
    # Tool names are normalized and checked for collisions. LittleGhost limits
    # catalog size, schema complexity, and returned media before creating Tool
    # classes. +tool_mapper+ and +result_mapper+ use the same Definition,
    # Result, and Call values as Toolset.
    #
    # The server chooses its definitions and results. LittleGhost checks their
    # structure before creating Tools, but the application still chooses which
    # servers and operations an Agent may use.
    #
    # A client and its transport represent one authenticated server session.
    # Create a separate pair for each authenticated user or service identity. Protocol
    # initialization and subsequent requests through one client are serialized;
    # do not share its transport with another client.
    class Client
      PreparedDefinition = Data.define(:definition, :input_schema, :output_schemer) # :nodoc:
      MAX_TOOL_NAME_LENGTH = 64 # :nodoc:
      ALIAS_DIGEST_LENGTH = 12 # :nodoc:
      DEFAULT_MAX_TOOLS = 1_000 # :nodoc:
      DEFAULT_MAX_PAGES = 100 # :nodoc:
      DEFAULT_MAX_DISCOVERY_BYTES = 10 * 1024 * 1024 # :nodoc:
      DEFAULT_MAX_DISCOVERY_NODES = 100_000 # :nodoc:
      DEFAULT_MAX_CURSOR_BYTES = 16 * 1024 # :nodoc:
      DEFAULT_MAX_DEFINITION_DEPTH = 64 # :nodoc:
      DEFAULT_MAX_DEFINITION_NODES = 10_000 # :nodoc:
      DEFAULT_MAX_SCHEMA_PATTERNS = 1_000 # :nodoc:
      DEFAULT_MAX_SCHEMA_PATTERN_BYTES = 1024 * 1024 # :nodoc:
      DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES = 64 * 1024 # :nodoc:
      DEFAULT_MAX_IMAGES = 20 # :nodoc:
      DEFAULT_MAX_IMAGE_BYTES = 16 * 1024 * 1024 # :nodoc:
      DEFAULT_MAX_TOTAL_IMAGE_BYTES = 64 * 1024 * 1024 # :nodoc:
      ECMA_REGEXP_RESOLVER = lambda do |pattern| # :nodoc:
        source = JSONSchemer::EcmaRegexp.ruby_equivalent(pattern)
        Regexp.new(source, timeout: Tool::SchemaValidator::REGEXP_TIMEOUT)
      end

      # Uses a transport that responds to +send+. +tool_mapper+ receives each
      # generated Tool class and may return a configured class or nil.
      # +result_mapper+ receives Result and Call values. Catalog, schema, and
      # media limits use fixed framework defaults.
      def initialize(
        transport:,
        name: "mcp",
        tool_mapper: nil,
        result_mapper: nil
      )
        validate_callback(tool_mapper, :tool_mapper)
        validate_callback(result_mapper, :result_mapper)

        @transport = transport
        @name = String(name)
        @tool_mapper = tool_mapper
        @result_mapper = result_mapper
        @max_tools = DEFAULT_MAX_TOOLS
        @max_pages = DEFAULT_MAX_PAGES
        @max_discovery_bytes = DEFAULT_MAX_DISCOVERY_BYTES
        @max_discovery_nodes = DEFAULT_MAX_DISCOVERY_NODES
        @max_definition_depth = DEFAULT_MAX_DEFINITION_DEPTH
        @max_definition_nodes = DEFAULT_MAX_DEFINITION_NODES
        @max_images = DEFAULT_MAX_IMAGES
        @max_image_bytes = DEFAULT_MAX_IMAGE_BYTES
        @max_total_image_bytes = DEFAULT_MAX_TOTAL_IMAGE_BYTES
        @request_id = 0
        @mutex = Mutex.new
        @initialization_mutex = Mutex.new
        @definitions_mutex = Mutex.new
        @definitions_by_name = {}
        @initialized = false
      end

      # Negotiates the protocol when needed, then provides Tool classes for the
      # server's current definitions.
      def tools(context: nil, binding: Tool::Binding.new)
        context&.check!
        ensure_initialized(context:)
        definitions = list_tool_definitions(context:).map do |raw|
          context&.check!
          build_definition(raw, context:).tap { context&.check! }
        end
        tools = definitions.filter_map do |definition|
          context&.check!
          build_tool(definition, binding:).tap { context&.check! }
        end
        index_tools!(tools, context:)
        context&.check!
        tools.freeze
      end

      # Calls a generated or named Tool and returns the common Tool execution
      # result. Names discovered through #tools resolve to their stored
      # Definition; an undiscovered name is treated as a source name.
      def call(name, arguments, context: nil, binding: Tool::Binding.new)
        context&.check!
        ensure_initialized(context:)
        prepared = if name.is_a?(PreparedDefinition)
          name
        elsif name.is_a?(Definition)
          prepare_definition(name, context:)
        else
          definition_for_call(name, context:)
        end
        definition = prepared.definition
        call_value = Call.new(definition:, arguments:, context:, binding:)
        raw = request(
          "tools/call",
          {name: definition.source_name, arguments: call_value.arguments.to_h},
          context:
        )
        result = build_result(raw, prepared:)
        context&.check!
        mapped = if @result_mapper
          @result_mapper.call(result, call: call_value, binding:)
        else
          default_value(result)
        end
        context&.check!
        tool_result(mapped, protocol_result: result)
      end

      private

      def ensure_initialized(context:)
        @initialization_mutex.synchronize do
          initialize_protocol(context:) unless @initialized
        end
      end

      def initialize_protocol(context:)
        result = request("initialize", {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: {name: "little_ghost", version: LittleGhost::VERSION}
        }, context:)
        unless result["protocolVersion"].to_s == PROTOCOL_VERSION
          raise ProtocolError, "MCP server did not negotiate protocol #{PROTOCOL_VERSION}"
        end
        unless result["capabilities"].is_a?(Hash)
          raise ProtocolError, "MCP initialize result must include capabilities"
        end
        server_info = result["serverInfo"]
        unless server_info.is_a?(Hash) &&
            server_info["name"].is_a?(String) && !server_info["name"].empty? &&
            server_info["version"].is_a?(String) && !server_info["version"].empty?
          raise ProtocolError, "MCP initialize result must include serverInfo name and version"
        end

        notify("notifications/initialized", context:)
        @initialized = true
      end

      def request(method, params = {}, context: nil)
        context&.check!
        expected_id, response = @mutex.synchronize do
          @request_id += 1
          [@request_id, @transport.send(
            {jsonrpc: "2.0", id: @request_id, method: method, params: params},
            context:
          )]
        end
        context&.check!
        raise ProtocolError, "MCP response must be an object" unless response.is_a?(Hash)
        raise ProtocolError, "MCP response must use JSON-RPC 2.0" unless response["jsonrpc"] == "2.0"
        unless response.key?("id") && response["id"] == expected_id
          raise ProtocolError, "MCP response ID did not match its request"
        end
        has_result = response.key?("result")
        has_error = response.key?("error")
        unless has_result ^ has_error
          raise ProtocolError, "MCP response must include exactly one of result or error"
        end
        if has_error
          error = response["error"]
          raise ProtocolError, "MCP response error must be an object" unless error.is_a?(Hash)
          unless error["code"].is_a?(Integer) && error["message"].is_a?(String)
            raise ProtocolError, "MCP response error must include an integer code and string message"
          end

          message = error["message"]
          raise ToolError, message.empty? ? "MCP request failed" : message
        end
        result = response["result"]
        raise ProtocolError, "MCP response did not include a result object" unless result.is_a?(Hash)

        result
      end

      def notify(method, params = {}, context: nil)
        context&.check!
        @transport.send({jsonrpc: "2.0", method: method, params: params}, context:).tap do
          context&.check!
        end
      end

      def list_tool_definitions(context:)
        definitions = []
        discovery_bytes = 0
        discovery_nodes = 0
        cursor = nil
        seen_cursors = {}
        pages = 0
        loop do
          context&.check!
          pages += 1
          raise ProtocolError, "MCP tools/list exceeded #{@max_pages} pages" if pages > @max_pages

          result = request("tools/list", cursor ? {cursor: cursor} : {}, context:)
          context&.check!
          tools = result.fetch("tools", [])
          raise ProtocolError, "MCP tools/list tools must be an array" unless tools.is_a?(Array)

          tools.each do |definition|
            context&.check!
            bytes, nodes = definition_complexity(definition, context:)
            discovery_bytes += bytes
            discovery_nodes += nodes
            if discovery_bytes > @max_discovery_bytes
              raise ProtocolError, "MCP tools/list exceeded the #{@max_discovery_bytes}-byte definition limit"
            end
            if discovery_nodes > @max_discovery_nodes
              raise ProtocolError, "MCP tools/list exceeded the #{@max_discovery_nodes}-node definition limit"
            end
          end
          definitions.concat(tools)
          raise ProtocolError, "MCP tools/list exceeded #{@max_tools} tools" if definitions.length > @max_tools
          cursor = result["nextCursor"]
          break if cursor.nil?
          unless cursor.is_a?(String) && !cursor.empty?
            raise ProtocolError, "MCP tools/list nextCursor must be a non-empty string"
          end
          if cursor.bytesize > DEFAULT_MAX_CURSOR_BYTES
            raise ProtocolError, "MCP tools/list nextCursor exceeded the #{DEFAULT_MAX_CURSOR_BYTES}-byte limit"
          end
          discovery_bytes += cursor.bytesize
          if discovery_bytes > @max_discovery_bytes
            raise ProtocolError, "MCP tools/list exceeded the #{@max_discovery_bytes}-byte definition limit"
          end

          raise ProtocolError, "MCP tools/list repeated a pagination cursor" if seen_cursors[cursor]

          seen_cursors[cursor] = true
        end
        context&.check!
        definitions
      end

      def build_tool(prepared, binding:)
        definition = prepared.definition
        client = self
        tool_class = Class.new(Tool) do
          tool_name definition.name
          description definition.description
          input_schema prepared.input_schema

          define_singleton_method(:mcp_definition) { definition }
          define_method(:call) do |input|
            client.call(prepared, input, context:, binding: self.binding)
          end
        end
        tool_class.instance_variable_set(:@little_ghost_mcp_prepared_definition, prepared)
        return tool_class unless @tool_mapper

        mapped = @tool_mapper.call(tool_class, definition:, binding:)
        return if mapped.nil?
        unless mapped.is_a?(Class) && mapped <= tool_class
          raise ConfigurationError, "MCP tool mapper must return the generated Tool class, a subclass, or nil"
        end

        mapped.instance_variable_set(:@little_ghost_mcp_prepared_definition, prepared)
        mapped
      end

      def build_definition(raw, context: nil)
        context&.check!
        source_name = definition_name(raw)
        definition = Definition.new(
          source_name:,
          name: safe_name(source_name),
          description: present_description(raw["description"]),
          input_schema: raw.fetch("inputSchema", {type: "object"}),
          output_schema: raw["outputSchema"],
          annotations: raw.fetch("annotations", {}),
          title: raw["title"],
          metadata: raw.fetch("_meta", {}),
          raw:
        )
        prepare_definition(definition, context:)
      rescue SystemStackError
        raise ProtocolError, "MCP tool definition exceeds the supported nesting limit"
      end

      def definition_complexity(definition, context:)
        nodes = 0
        bytes = 0
        stack = [[definition, 1]]
        until stack.empty?
          value, depth = stack.pop
          raise ProtocolError, "MCP tool definition exceeds the #{@max_definition_depth}-level depth limit" if depth > @max_definition_depth

          nodes += 1
          if nodes > @max_definition_nodes
            raise ProtocolError, "MCP tool definition exceeds the #{@max_definition_nodes}-node limit"
          end
          context&.check! if (nodes % 1_000).zero?
          case value
          when Hash
            bytes += 2
            value.each do |key, child|
              raise ProtocolError, "MCP tool definition keys must be strings" unless key.is_a?(String)

              bytes += key.bytesize + 3
              stack << [child, depth + 1]
            end
          when Array
            bytes += 2 + value.length
            value.each { |child| stack << [child, depth + 1] }
          when String
            bytes += value.bytesize + 2
          when Numeric
            bytes += value.to_s.bytesize
          when true, false
            bytes += value ? 4 : 5
          when nil
            bytes += 4
          else
            raise ProtocolError, "MCP tool definition contains a non-JSON value"
          end
        end
        [bytes, nodes]
      end

      def definition_name(definition)
        raise ProtocolError, "MCP tool definition must be an object" unless definition.is_a?(Hash)

        name = definition["name"]
        raise ProtocolError, "MCP tool definition must include a name" unless name.is_a?(String) && !name.empty?

        name
      end

      def safe_name(name)
        normalized = name.gsub(/[^a-zA-Z0-9_-]/, "_")
        raise ConfigurationError, "MCP tool name cannot be empty" if normalized.empty?
        return normalized if normalized.length <= MAX_TOOL_NAME_LENGTH

        digest = Digest::SHA256.hexdigest(normalized)[0, ALIAS_DIGEST_LENGTH]
        prefix_length = MAX_TOOL_NAME_LENGTH - ALIAS_DIGEST_LENGTH - 1
        "#{normalized[0, prefix_length]}_#{digest}"
      end

      def present_description(description)
        value = description.to_s
        value.empty? ? "MCP tool from #{@name}" : value
      end

      def index_tools!(tools, context: nil)
        indexed = {}
        tools.each do |tool_class|
          context&.check!
          definition = tool_class.mcp_definition
          name = tool_class.tool_name
          existing = indexed[name]
          if existing && existing.definition.source_name != definition.source_name
            raise ConfigurationError,
              "MCP tools #{existing.definition.source_name.inspect} and #{definition.source_name.inspect} map to #{name.inspect}"
          end
          prepared = tool_class.instance_variable_get(:@little_ghost_mcp_prepared_definition)
          prepared ||= prepare_definition(definition, context:)
          indexed[name] = prepared
        end
        @definitions_mutex.synchronize { @definitions_by_name = indexed.freeze }
      end

      def definition_for_call(name, context: nil)
        value = String(name)
        @definitions_mutex.synchronize { @definitions_by_name[value] } || prepare_definition(Definition.new(
          source_name: value,
          name: safe_name(value),
          description: "MCP tool from #{@name}",
          input_schema: {type: "object"},
          raw: {name: value}
        ), context:)
      end

      def build_result(raw, prepared:)
        result = Result.new(
          content: raw.fetch("content", []),
          structured_content: raw["structuredContent"],
          error: raw["isError"],
          metadata: raw.fetch("_meta", {}),
          raw:
        )
        validate_result_blocks!(result.content)
        validate_structured_content!(result, prepared:)
        result
      end

      def validate_result_blocks!(content)
        content.each do |block|
          raise ProtocolError, "MCP tool result content blocks must be objects" unless block.is_a?(Hash)
          raise ProtocolError, "MCP tool result content blocks must include a type" unless block["type"].is_a?(String)
          if block["type"] == "text" && !block["text"].is_a?(String)
            raise ProtocolError, "MCP text content must include text"
          end
        end
      end

      def validate_structured_content!(result, prepared:)
        definition = prepared.definition
        schema = definition.output_schema
        return unless schema
        raise ProtocolError, "MCP tool result omitted structuredContent required by outputSchema" unless result.structured_content

        errors = prepared.output_schemer.validate(result.structured_content.to_h).take(10)
        return if errors.empty?

        details = errors.filter_map { |error| error["error"] }.join("; ")
        raise ProtocolError, "MCP structuredContent did not match outputSchema: #{details}"
      rescue JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer
        raise ProtocolError, "MCP outputSchema contains an unresolved reference"
      rescue Regexp::TimeoutError
        raise ProtocolError, "MCP structuredContent exceeded the outputSchema pattern time limit"
      end

      def prepare_definition(definition, context: nil)
        context&.check!
        input_schema = normalized_input_schema(definition.input_schema, context:)
        schema = definition.output_schema
        return PreparedDefinition.new(definition:, input_schema:, output_schemer: nil) unless schema

        schema_hash = schema.to_h
        schema_patterns(schema_hash, field: "outputSchema", context:)
        context&.check!
        errors = JSONSchemer.validate_schema(schema_hash).take(10)
        unless errors.empty?
          details = errors.filter_map { |error| error["error"] }.join("; ")
          raise ProtocolError, "MCP tool outputSchema is invalid: #{details}"
        end

        schemer = JSONSchemer.schema(schema_hash, regexp_resolver: ECMA_REGEXP_RESOLVER)
        context&.check!
        PreparedDefinition.new(definition:, input_schema:, output_schemer: schemer)
      rescue JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer
        raise ProtocolError, "MCP tool outputSchema contains an unresolved reference"
      end

      def normalized_input_schema(schema, context: nil)
        normalized = JSON.parse(JSON.generate(schema.to_h))
        schema_patterns(normalized, field: "inputSchema", context:).each do |container, key, regexp|
          context&.check!
          container[key] = regexp.source if container
        end
        normalized
      rescue JSON::GeneratorError, JSON::ParserError
        raise ProtocolError, "MCP tool inputSchema is not valid JSON"
      end

      def schema_patterns(schema, field:, context: nil)
        patterns = []
        total_bytes = 0
        stack = [schema]
        until stack.empty?
          context&.check!
          value = stack.pop
          case value
          when Hash
            if value.key?("pattern")
              pattern = value["pattern"]
              unless pattern.is_a?(String)
                raise ProtocolError, "MCP tool #{field} pattern must be a string"
              end
              patterns << [value, "pattern", pattern]
            end
            pattern_properties = value["patternProperties"]
            if pattern_properties
              unless pattern_properties.is_a?(Hash)
                raise ProtocolError, "MCP tool #{field} patternProperties must be an object"
              end
              pattern_properties.each_key { |pattern| patterns << [nil, nil, pattern] }
            end
            value.each_value { |child| stack << child }
          when Array
            value.each { |child| stack << child }
          end
        end
        if patterns.length > DEFAULT_MAX_SCHEMA_PATTERNS
          raise ProtocolError, "MCP tool #{field} exceeded the #{DEFAULT_MAX_SCHEMA_PATTERNS}-pattern limit"
        end

        patterns.map do |container, key, pattern|
          context&.check!
          unless pattern.is_a?(String)
            raise ProtocolError, "MCP tool #{field} pattern must be a string"
          end
          if pattern.bytesize > DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES
            raise ProtocolError,
              "MCP tool #{field} pattern exceeded the #{DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES}-byte limit"
          end
          total_bytes += pattern.bytesize
          if total_bytes > DEFAULT_MAX_SCHEMA_PATTERN_BYTES
            raise ProtocolError,
              "MCP tool #{field} patterns exceeded the #{DEFAULT_MAX_SCHEMA_PATTERN_BYTES}-byte total limit"
          end
          [container, key, ECMA_REGEXP_RESOLVER.call(pattern)]
        end
      rescue JSONSchemer::InvalidEcmaRegexp, RegexpError
        raise ProtocolError, "MCP tool #{field} contains an invalid pattern"
      end

      def tool_result(mapped, protocol_result:)
        media = image_artifacts(protocol_result.content)
        mapped = default_value(mapped) if mapped.is_a?(Result)
        value, artifacts = if mapped.is_a?(Tool::Result)
          [mapped.value, [*mapped.artifacts, *media]]
        else
          [mapped, media]
        end
        raise ToolError, serialize_value(value) if protocol_result.error?

        Tool::Result.new(value:, artifacts:)
      end

      def default_value(result)
        return result.structured_content if result.structured_content

        text = result.content.filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
        return text unless text.empty?

        visible = result.content.reject { |block| block["type"] == "image" }
        return visible unless visible.empty?

        ImmutableValue.mapping({
          "images" => result.content.filter_map do |block|
            next unless block["type"] == "image"

            {
              "mediaType" => block["mimeType"],
              "name" => block["name"],
              "bytes" => strict_base64_bytesize(block["data"])
            }.compact
          end
        }, field: "image result")
      end

      def image_artifacts(content)
        images = content.select { |block| block["type"] == "image" }
        if images.length > @max_images
          raise ProtocolError, "MCP image content exceeds the #{@max_images}-image limit"
        end

        total_bytes = 0
        images.map do |block|
          data = block["data"]
          media_type = block["mimeType"]
          unless data.is_a?(String) && media_type.is_a?(String) && media_type.start_with?("image/")
            raise ProtocolError, "MCP image content is invalid"
          end
          decoded_bytes = strict_base64_bytesize(data)
          if decoded_bytes > @max_image_bytes
            raise ProtocolError, "MCP image content exceeds the #{@max_image_bytes}-byte per-image limit"
          end
          total_bytes += decoded_bytes
          if total_bytes > @max_total_image_bytes
            raise ProtocolError, "MCP image content exceeds the #{@max_total_image_bytes}-byte total limit"
          end
          Artifact.new(
            data: Base64.strict_decode64(data),
            media_type:,
            name: block["name"]
          )
        rescue ArgumentError
          raise ProtocolError, "MCP image content data must use strict base64"
        end
      end

      def strict_base64_bytesize(data)
        raise ArgumentError unless data.bytesize % 4 == 0
        raise ArgumentError unless /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/.match?(data)

        padding = if data.end_with?("==")
          2
        elsif data.end_with?("=")
          1
        else
          0
        end
        (data.bytesize / 4 * 3) - padding
      end

      def serialize_value(value)
        case value
        when String then value
        when nil then ""
        when Hash, Array then JSON.generate(value)
        else value.to_s
        end
      rescue JSON::GeneratorError
        raise ToolError, "MCP result transformation could not be serialized"
      end

      def validate_callback(value, name)
        return unless value
        raise ArgumentError, "#{name} must respond to call" unless value.respond_to?(:call)
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end
    end

    # SigV4Signer adds AWS Signature Version 4 authentication to MCP requests.
    # Requires the application-provided +aws-sigv4+ gem and uses its normal AWS
    # credentials-provider chain unless one is supplied explicitly.
    class SigV4Signer
      # Configures signing for +service+ and +region+.
      def initialize(service:, region:, credentials_provider: nil)
        require "aws-sigv4"
        @signer = Aws::Sigv4::Signer.new(
          service: service,
          region: region,
          credentials_provider: credentials_provider
        )
      rescue LoadError
        raise ConfigurationError, "MCP SigV4 signing requires the optional aws-sigv4 gem"
      end

      # Signs +request+ in place immediately before transport.
      def call(request)
        signature = @signer.sign_request(
          http_method: request.method,
          url: request.uri,
          headers: request.to_hash.transform_values { |values| Array(values).join(",") },
          body: request.body
        )
        signature.headers.each { |name, value| request[name] = value }
      end
    end
  end
end
