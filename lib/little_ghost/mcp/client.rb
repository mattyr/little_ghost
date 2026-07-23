# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module LittleGhost
  module MCP
    PROTOCOL_VERSION = "2025-06-18"

    class HTTPTransport
      DEFAULT_MAX_RESPONSE_BYTES = 10 * 1024 * 1024
      SESSION_ID_PATTERN = /\A[\x21-\x7e]{1,256}\z/

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

    class Client
      MAX_TOOL_NAME_LENGTH = 64
      ALIAS_DIGEST_LENGTH = 12
      DEFAULT_MAX_TOOLS = 1_000
      DEFAULT_MAX_PAGES = 100

      def initialize(transport:, name: "mcp", prefix: nil, rejected_tools: [], max_tools: DEFAULT_MAX_TOOLS,
        max_pages: DEFAULT_MAX_PAGES)
        @transport = transport
        @name = String(name)
        @prefix = prefix&.to_s
        @rejected_tools = rejected_tools.map(&:to_s).freeze
        @max_tools = positive_integer(max_tools, :max_tools)
        @max_pages = positive_integer(max_pages, :max_pages)
        @request_id = 0
        @mutex = Mutex.new
        @source_names = {}
        @initialized = false
      end

      def tools(context: nil)
        initialize_protocol(context:) unless @initialized
        definitions = list_tool_definitions(context:)
        definitions.filter_map do |definition|
          source_name = definition_name(definition)
          next if @rejected_tools.include?(source_name)

          build_tool(definition)
        end
      end

      def call(name, arguments, context: nil)
        source_name = @source_names.fetch(name.to_s, name.to_s)
        result = request("tools/call", {name: source_name, arguments: arguments}, context:)
        content = serialize_result(result)
        raise ToolError, content if result["isError"]

        content
      end

      private

      def initialize_protocol(context:)
        result = request("initialize", {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: {name: "little_ghost", version: LittleGhost::VERSION}
        }, context:)
        unless result["protocolVersion"].to_s == PROTOCOL_VERSION
          raise ProtocolError, "MCP server did not negotiate protocol #{PROTOCOL_VERSION}"
        end

        notify("notifications/initialized", context:)
        @initialized = true
      end

      def request(method, params = {}, context: nil)
        expected_id, response = @mutex.synchronize do
          @request_id += 1
          [@request_id, @transport.send(
            {jsonrpc: "2.0", id: @request_id, method: method, params: params},
            context:
          )]
        end
        raise ProtocolError, "MCP response must be an object" unless response.is_a?(Hash)
        if (error = response["error"])
          raise ProtocolError, "MCP response error must be an object" unless error.is_a?(Hash)

          message = error["message"].to_s
          raise ToolError, message.empty? ? "MCP request failed" : message
        end
        if response.key?("id") && response["id"] != expected_id
          raise ProtocolError, "MCP response ID did not match its request"
        end

        result = response["result"]
        raise ProtocolError, "MCP response did not include a result object" unless result.is_a?(Hash)

        result
      end

      def notify(method, params = {}, context: nil)
        @transport.send({jsonrpc: "2.0", method: method, params: params}, context:)
      end

      def list_tool_definitions(context:)
        definitions = []
        cursor = nil
        seen_cursors = {}
        pages = 0
        loop do
          pages += 1
          raise ProtocolError, "MCP tools/list exceeded #{@max_pages} pages" if pages > @max_pages

          result = request("tools/list", cursor ? {cursor: cursor} : {}, context:)
          tools = result.fetch("tools", [])
          raise ProtocolError, "MCP tools/list tools must be an array" unless tools.is_a?(Array)

          definitions.concat(tools)
          raise ProtocolError, "MCP tools/list exceeded #{@max_tools} tools" if definitions.length > @max_tools
          cursor = result["nextCursor"]
          break if cursor.nil? || cursor.empty?

          raise ProtocolError, "MCP tools/list repeated a pagination cursor" if seen_cursors[cursor]

          seen_cursors[cursor] = true
        end
        definitions
      end

      def build_tool(definition)
        client = self
        source_name = definition_name(definition)
        exposed_name = safe_name([@prefix, source_name].compact.join("___"))
        existing = @source_names[exposed_name]
        if existing && existing != source_name
          raise ConfigurationError, "MCP tools #{existing.inspect} and #{source_name.inspect} map to #{exposed_name.inspect}"
        end
        @source_names[exposed_name] = source_name

        Tool.define(
          name: exposed_name,
          description: present_description(definition["description"]),
          input_schema: definition.fetch("inputSchema", {type: "object"})
        ) { |input, context:| client.call(exposed_name, input, context:) }
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

      def serialize_content(content)
        text = content.filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
        return text unless text.empty?

        JSON.generate(content)
      end

      def serialize_result(result)
        return serialize_content(result.fetch("content", [])) unless result.key?("structuredContent")

        structured = result["structuredContent"]
        raise ProtocolError, "MCP structuredContent must be an object" unless structured.is_a?(Hash)

        payload = {"structuredContent" => structured}
        content = result.fetch("content", [])
        payload["content"] = content unless content.empty?
        JSON.generate(payload)
      end

      def positive_integer(value, name)
        integer = Integer(value)
        raise ArgumentError, "#{name} must be positive" unless integer.positive?

        integer
      end
    end

    class SigV4Signer
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
