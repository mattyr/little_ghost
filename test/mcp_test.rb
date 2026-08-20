# frozen_string_literal: true

require "test_helper"
require "little_ghost/mcp"
require "base64"

class MCPTest < Minitest::Test
  class Transport
    attr_reader :contexts, :payloads

    def initialize(tools: nil, results: nil)
      @tools = tools || [{
        "name" => "search",
        "description" => "Search",
        "inputSchema" => {"type" => "object"}
      }]
      configured_results = results || {"content" => [{"type" => "text", "text" => "found"}]}
      @results = configured_results.is_a?(Array) ? configured_results : [configured_results]
      @contexts = []
      @payloads = []
    end

    def send(payload, context: nil)
      contexts << context
      payloads << payload
      case payload[:method]
      when "initialize"
        self.class.response(payload, {
          "protocolVersion" => LittleGhost::MCP::PROTOCOL_VERSION,
          "capabilities" => {},
          "serverInfo" => {"name" => "test", "version" => "1.0"}
        })
      when "notifications/initialized"
        {}
      when "tools/list"
        self.class.response(payload, {"tools" => @tools})
      when "tools/call"
        self.class.response(payload, ((@results.length > 1) ? @results.shift : @results.first))
      end
    end

    def self.response(payload, result)
      {"jsonrpc" => "2.0", "id" => payload.fetch(:id), "result" => result}
    end
  end

  def test_client_generates_normal_tools_and_preserves_machine_values
    transport = Transport.new(results: {
      "content" => [{"type" => "text", "text" => "summary"}],
      "structuredContent" => {"items" => [1, 2]}
    })
    tool_class = LittleGhost::MCP::Client.new(transport:).tools.first

    result = tool_class.new.execute({"query" => "ruby"})

    assert_operator tool_class, :<, LittleGhost::Tool
    assert_equal "search", tool_class.tool_name
    assert_equal({"items" => [1, 2]}, result.value)
    assert_equal({"items" => [1, 2]}.to_json, result.content)
    assert_equal "search", transport.payloads.last.dig(:params, :name)
    assert_equal %w[initialize notifications/initialized tools/list tools/call],
      transport.payloads.map { |payload| payload[:method] }
  end

  def test_direct_call_initializes_the_protocol
    transport = Transport.new

    result = LittleGhost::MCP::Client.new(transport:).call("search", {})

    assert_equal "found", result.value
    assert_equal %w[initialize notifications/initialized tools/call],
      transport.payloads.map { |payload| payload[:method] }
  end

  def test_client_enforces_cancellation_when_the_transport_does_not
    token = LittleGhost::Support::CancellationToken.new.cancel
    context = LittleGhost::RunContext.new(cancellation_token: token)
    transport = Transport.new

    assert_raises(LittleGhost::CancelledError) do
      LittleGhost::MCP::Client.new(transport:).tools(context:)
    end
    assert_empty transport.payloads
  end

  def test_client_checks_cancellation_after_transport_responses
    token = LittleGhost::Support::CancellationToken.new
    context = LittleGhost::RunContext.new(cancellation_token: token)
    transport = Transport.new
    original_send = transport.method(:send)
    transport.define_singleton_method(:send) do |payload, context: nil|
      response = original_send.call(payload, context:)
      token.cancel if payload[:method] == "initialize"
      response
    end

    assert_raises(LittleGhost::CancelledError) do
      LittleGhost::MCP::Client.new(transport:).tools(context:)
    end
  end

  def test_toolset_resolves_one_connection_for_the_current_binding
    binding = LittleGhost::Tool::Binding.new(workspace: Object.new)
    seen = nil
    options = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection do |current|
        seen = current
        {
          url: "https://mcp.example/rpc",
          headers: {Authorization: "Bearer token"},
          timeout: 12,
          max_response_bytes: 4096
        }
      end
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, lambda { |**values|
      options = values
      Transport.new
    }) do
      assert_equal ["search"], toolset.tools(binding).map(&:tool_name)
    end

    assert_same binding, seen
    assert_equal "https://mcp.example/rpc", options.fetch(:url)
    assert_equal({"Authorization" => "Bearer token"}, options.fetch(:headers))
    assert_equal 12, options.fetch(:timeout)
    assert_equal 4096, options.fetch(:max_response_bytes)
  end

  def test_toolset_map_tool_can_omit_and_rename_without_changing_dispatch
    transport = Transport.new(tools: [
      {"name" => "search", "description" => "Search"},
      {"name" => "delete", "description" => "Delete"}
    ])
    definitions = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      map_tool do |tool_class, definition:, binding:|
        definitions << [definition, binding]
        next if definition.source_name == "delete"

        tool_class.tool_name "knowledge_search"
        tool_class
      end
    end
    binding = LittleGhost::Tool::Binding.new

    LittleGhost::MCP::HTTPTransport.stub(:new, transport) do
      tool_class = toolset.tools(binding).fetch(0)
      result = tool_class.new.execute({})

      assert_equal "knowledge_search", tool_class.tool_name
      assert_equal "found", result.value
    end

    assert_equal %w[search delete], definitions.map { |definition, _| definition.source_name }
    assert definitions.all? { |_, current| current.equal?(binding) }
    assert_equal "search", transport.payloads.last.dig(:params, :name)
  end

  def test_toolset_map_result_receives_immutable_values_and_can_return_artifacts
    seen = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      map_result do |result, call:, binding:|
        seen = [result, call, binding]
        LittleGhost::Tool::Result.new(
          value: {"mapped" => result.content.first.fetch("text")},
          artifacts: [LittleGhost::Artifact.deferred(
            reference: "record:1",
            media_type: "application/octet-stream"
          )]
        )
      end
    end
    binding = LittleGhost::Tool::Binding.new

    LittleGhost::MCP::HTTPTransport.stub(:new, Transport.new) do
      result = toolset.tools(binding).first.new(binding:).execute({})

      assert_equal({"mapped" => "found"}, result.value)
      assert_equal "record:1", result.artifacts.first.reference
    end

    protocol_result, call, current_binding = seen
    assert_instance_of LittleGhost::MCP::Result, protocol_result
    assert protocol_result.content.frozen?
    assert_instance_of LittleGhost::MCP::Call, call
    assert_same binding, current_binding
  end

  def test_map_result_can_pass_through_unhandled_protocol_results
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      map_result { |result, **| result }
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, Transport.new(results: {
      "structuredContent" => {"items" => [1, 2]}
    })) do
      result = toolset.tools(LittleGhost::Tool::Binding.new).first.new.execute({})

      assert_equal({"items" => [1, 2]}, result.value)
    end
  end

  def test_optional_toolset_reports_expected_discovery_failures
    observed = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection url: "https://mcp.example/rpc"
      optional true
      on_error { |error, binding:| observed << [error, binding] }
    end
    binding = LittleGhost::Tool::Binding.new

    LittleGhost::MCP::HTTPTransport.stub(:new, ->(**) { raise LittleGhost::ProviderError, "offline" }) do
      assert_empty toolset.tools(binding)
    end

    assert_instance_of LittleGhost::ProviderError, observed.first.first
    assert_same binding, observed.first.last
  end

  def test_optional_toolset_does_not_consume_application_callback_failures
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      connection { |_binding| raise LittleGhost::ToolError, "caller policy failed" }
      optional true
    end

    error = assert_raises(LittleGhost::ToolError) do
      toolset.tools(LittleGhost::Tool::Binding.new)
    end
    assert_equal "caller policy failed", error.message
  end

  def test_mcp_images_become_artifacts_without_retaining_base64_in_the_value
    encoded = Base64.strict_encode64("image-bytes")
    transport = Transport.new(results: {
      "content" => [{"type" => "image", "data" => encoded, "mimeType" => "image/png", "name" => "chart.png"}]
    })

    result = LittleGhost::MCP::Client.new(transport:).tools.first.new.execute({})

    assert_equal({"images" => [{"mediaType" => "image/png", "name" => "chart.png", "bytes" => 11}]}, result.value)
    refute_includes result.value.inspect, encoded
    artifact = result.artifacts.fetch(0)
    assert artifact.inline?
    assert_equal "image-bytes", artifact.data
    assert_equal "image/png", artifact.media_type
  end

  def test_mcp_image_limits_are_internal_and_applied_before_decode
    images = Array.new(LittleGhost::MCP::Client::DEFAULT_MAX_IMAGES + 1) do
      {"type" => "image", "data" => Base64.strict_encode64("x"), "mimeType" => "image/png"}
    end
    tool = LittleGhost::MCP::Client.new(
      transport: Transport.new(results: {"content" => images})
    ).tools.first.new

    result = tool.execute({})

    assert result.error?
    assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
  end

  def test_output_schema_is_validated_for_generated_tool_lifetime
    tools = [{
      "name" => "count",
      "outputSchema" => {
        "type" => "object",
        "properties" => {"count" => {"const" => 1}},
        "required" => ["count"]
      }
    }]
    transport = Transport.new(tools:, results: {"structuredContent" => {"count" => 1}})
    client = LittleGhost::MCP::Client.new(transport:)
    tool_class = client.tools.first

    GC.start
    result = tool_class.new.execute({})

    assert result.success?
    assert_equal({"count" => 1}, result.value)
  end

  def test_output_schema_rejects_invalid_structured_content
    tools = [{
      "name" => "count",
      "outputSchema" => {
        "type" => "object",
        "properties" => {"count" => {"const" => 1}},
        "required" => ["count"]
      }
    }]
    tool = LittleGhost::MCP::Client.new(
      transport: Transport.new(tools:, results: {"structuredContent" => {"count" => 2}})
    ).tools.first.new

    result = tool.execute({})

    assert result.error?
    assert_equal "Tool failed (LittleGhost::ProtocolError)", result.content
  end

  def test_protocol_errors_mark_generated_tool_results_as_errors
    tool = LittleGhost::MCP::Client.new(
      transport: Transport.new(results: {
        "content" => [{"type" => "text", "text" => "safe failure"}],
        "isError" => true
      })
    ).tools.first.new

    result = tool.execute({})

    assert result.error?
    assert_equal "safe failure", result.content
  end

  def test_discovery_initializes_once_across_concurrent_refreshes
    entered = Queue.new
    release = Queue.new
    transport = Transport.new
    original_send = transport.method(:send)
    transport.define_singleton_method(:send) do |payload, context: nil|
      if payload[:method] == "initialize"
        entered << true
        release.pop
      end
      original_send.call(payload, context:)
    end
    client = LittleGhost::MCP::Client.new(transport:)

    first = Thread.new { client.tools }
    entered.pop
    second = Thread.new { client.tools }
    release << true
    [first, second].each(&:value)

    assert_equal 1, transport.payloads.count { |payload| payload[:method] == "initialize" }
    assert_equal 2, transport.payloads.count { |payload| payload[:method] == "tools/list" }
  end

  def test_generated_tools_forward_run_context
    context = LittleGhost::RunContext.new
    transport = Transport.new
    tool = LittleGhost::MCP::Client.new(transport:).tools.first.new

    tool.execute({}, context:)

    assert_same context, transport.contexts.last
  end

  def test_loads_all_pages_and_rejects_repeated_cursors
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        @payloads << payload
        if payload[:params].empty?
          Transport.response(payload, {"tools" => [{"name" => "first"}], "nextCursor" => "page-2"})
        else
          Transport.response(payload, {"tools" => [{"name" => "second"}]})
        end
      end
    end.new
    assert_equal %w[first second], LittleGhost::MCP::Client.new(transport:).tools.map(&:tool_name)

    repeated = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        Transport.response(payload, {"tools" => [], "nextCursor" => "same"})
      end
    end.new
    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: repeated).tools
    end
  end

  def test_rejects_oversized_pagination_cursors
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        Transport.response(payload, {
          "tools" => [],
          "nextCursor" => "x" * (LittleGhost::MCP::Client::DEFAULT_MAX_CURSOR_BYTES + 1)
        })
      end
    end.new

    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport:).tools
    end
  end

  def test_rejects_malformed_json_rpc_response_envelopes
    invalid_responses = [
      ->(payload) { {"id" => payload[:id], "result" => {"tools" => []}} },
      ->(_payload) { {"jsonrpc" => "2.0", "result" => {"tools" => []}} },
      ->(payload) { {"jsonrpc" => "2.0", "id" => payload[:id] + 1, "result" => {"tools" => []}} },
      ->(payload) { {"jsonrpc" => "2.0", "id" => payload[:id]} },
      lambda do |payload|
        {
          "jsonrpc" => "2.0",
          "id" => payload[:id],
          "result" => {"tools" => []},
          "error" => {"message" => "failed"}
        }
      end
    ]

    invalid_responses.each do |invalid_response|
      transport = Transport.new
      original_send = transport.method(:send)
      transport.define_singleton_method(:send) do |payload, context: nil|
        next invalid_response.call(payload) if payload[:method] == "tools/list"

        original_send.call(payload, context:)
      end

      assert_raises(LittleGhost::ProtocolError) do
        LittleGhost::MCP::Client.new(transport:).tools
      end
    end
  end

  def test_rejects_incomplete_initialize_results
    invalid_results = [
      {
        "protocolVersion" => LittleGhost::MCP::PROTOCOL_VERSION,
        "serverInfo" => {"name" => "test", "version" => "1.0"}
      },
      {
        "protocolVersion" => LittleGhost::MCP::PROTOCOL_VERSION,
        "capabilities" => {},
        "serverInfo" => {"name" => "test"}
      }
    ]

    invalid_results.each do |invalid_result|
      transport = Transport.new
      original_send = transport.method(:send)
      transport.define_singleton_method(:send) do |payload, context: nil|
        next Transport.response(payload, invalid_result) if payload[:method] == "initialize"

        original_send.call(payload, context:)
      end

      assert_raises(LittleGhost::ProtocolError) do
        LittleGhost::MCP::Client.new(transport:).tools
      end
    end
  end

  def test_rejects_malformed_json_rpc_errors
    invalid_errors = [
      {"message" => "failed"},
      {"code" => -32_000, "message" => 123}
    ]

    invalid_errors.each do |invalid_error|
      transport = Transport.new
      original_send = transport.method(:send)
      transport.define_singleton_method(:send) do |payload, context: nil|
        if payload[:method] == "tools/list"
          next({"jsonrpc" => "2.0", "id" => payload[:id], "error" => invalid_error})
        end

        original_send.call(payload, context:)
      end

      assert_raises(LittleGhost::ProtocolError) do
        LittleGhost::MCP::Client.new(transport:).tools
      end
    end
  end

  def test_input_schema_patterns_use_ecmascript_semantics
    tools = [{
      "name" => "match",
      "inputSchema" => {
        "type" => "object",
        "properties" => {"value" => {"type" => "string", "pattern" => "^foo$"}}
      }
    }]
    tool = LittleGhost::MCP::Client.new(transport: Transport.new(tools:)).tools.first.new

    result = tool.execute({"value" => "x\nfoo\ny"})

    assert result.error?
    assert_match(/invalid format/, result.content)
  end

  def test_rejects_invalid_or_oversized_schema_patterns
    invalid = [{
      "name" => "invalid",
      "inputSchema" => {"type" => "string", "pattern" => "(?i:a)"}
    }]
    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: Transport.new(tools: invalid)).tools
    end

    oversized = [{
      "name" => "oversized",
      "outputSchema" => {
        "type" => "object",
        "properties" => {
          "value" => {
            "type" => "string",
            "pattern" => "x" * (LittleGhost::MCP::Client::DEFAULT_MAX_SCHEMA_PATTERN_SOURCE_BYTES + 1)
          }
        }
      }
    }]
    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: Transport.new(tools: oversized)).tools
    end
  end

  def test_normalizes_and_bounds_model_visible_names
    tools = [{"name" => "search." + ("a" * 100)}]

    name = LittleGhost::MCP::Client.new(transport: Transport.new(tools:)).tools.first.tool_name

    assert_equal 64, name.length
    assert_match(/_[a-f0-9]{12}\z/, name)
  end

  def test_rejects_malformed_protocol_values
    malformed = Class.new(Transport) do
      def send(payload, context: nil)
        return Transport.response(payload, {"tools" => "invalid"}) if payload[:method] == "tools/list"

        super
      end
    end.new

    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: malformed).tools
    end
  end
end
