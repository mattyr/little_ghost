# frozen_string_literal: true

require "test_helper"
require "little_ghost/mcp"
require "socket"

class MCPTest < Minitest::Test
  class Transport
    attr_reader :contexts, :payloads

    def initialize(tool_name: "search")
      @tool_name = tool_name
      @contexts = []
      @payloads = []
    end

    def send(payload, context: nil)
      @contexts << context
      @payloads << payload
      case payload[:method]
      when "initialize"
        {"result" => {"protocolVersion" => LittleGhost::MCP::PROTOCOL_VERSION}}
      when "notifications/initialized"
        {}
      when "tools/list"
        {"result" => {"tools" => [{
          "name" => @tool_name,
          "description" => "Search",
          "inputSchema" => {"type" => "object"}
        }]}}
      when "tools/call"
        {"result" => {"content" => [{"type" => "text", "text" => "found"}]}}
      end
    end
  end

  def test_initializes_loads_and_calls_tools
    transport = Transport.new
    client = LittleGhost::MCP::Client.new(transport: transport, prefix: "web")

    tool = client.tools.first.new
    result = tool.execute({"query" => "ruby"})

    assert_equal "web___search", tool.class.tool_name
    assert_equal "found", result.content
    assert_equal "search", transport.payloads.last.dig(:params, :name)
    assert_equal %w[initialize notifications/initialized tools/list tools/call], transport.payloads.map { |item| item[:method] }
  end

  def test_toolset_loads_exposed_tools_through_the_agent_tool_provider_contract
    transports = []
    transport_class = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        @payloads << payload
        {"result" => {"tools" => [
          {"name" => "search", "description" => "Search"},
          {"name" => "fetch", "description" => "Fetch"}
        ]}}
      end
    end
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc", timeout: 20
      headers { {"Authorization" => "Bearer token"} }
      prefix "help_center"
      expose "search"
    end
    transport_factory = lambda do |**options|
      transports << [transport_class.new, options]
      transports.last.first
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, transport_factory) do
      registry = LittleGhost::ToolRegistry.new(
        [toolset],
        binding: LittleGhost::Tool::Binding.new(run: Object.new)
      )

      assert_equal ["help_center___search"], registry.names
      assert_equal "found", registry.fetch("help_center___search").execute({}).content
    ensure
      registry&.close
    end

    assert_equal "https://mcp.example/rpc", transports.first.last.fetch(:url)
    assert_equal 20, transports.first.last.fetch(:timeout)
    assert_equal({"Authorization" => "Bearer token"}, transports.first.last.fetch(:headers))
  end

  def test_toolset_resolves_headers_for_each_run_and_does_not_share_clients
    runs = [Object.new, Object.new]
    resolved_runs = []
    transports = []
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
      headers do |run|
        resolved_runs << run
        {"Authorization" => "Bearer #{runs.index(run)}"}
      end
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, ->(**) { Transport.new.tap { |transport| transports << transport } }) do
      runs.each do |run|
        registry = LittleGhost::ToolRegistry.new(
          [toolset],
          binding: LittleGhost::Tool::Binding.new(run:)
        )
        registry.fetch("search").execute({})
        registry.close
      end
    end

    assert_equal runs, resolved_runs
    assert_equal 2, transports.length
    assert_equal 2, transports.map(&:object_id).uniq.length
    assert_equal 2, transports.sum { |transport| transport.payloads.count { |payload| payload[:method] == "initialize" } }
  end

  def test_toolset_passes_run_cancellation_and_deadlines_to_discovery
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        context&.check!
        super
      end
    end.new
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, transport) do
      token = LittleGhost::Support::CancellationToken.new
      token.cancel
      cancelled = LittleGhost::RunContext.new(cancellation_token: token)
      run = Struct.new(:context).new(cancelled)
      assert_raises(LittleGhost::CancelledError) do
        toolset.tools(LittleGhost::Tool::Binding.new(run:))
      end

      expired = LittleGhost::RunContext.new(deadline: Time.now - 1)
      run = Struct.new(:context).new(expired)
      assert_raises(LittleGhost::DeadlineExceededError) do
        toolset.tools(LittleGhost::Tool::Binding.new(run:))
      end
    end
  end

  def test_toolset_accepts_zero_argument_header_resolvers
    options = nil
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
      headers -> { {"Authorization" => "Bearer token"} }
    end

    factory = lambda do |**values|
      options = values
      Transport.new
    end
    LittleGhost::MCP::HTTPTransport.stub(:new, factory) do
      registry = LittleGhost::ToolRegistry.new([toolset])
      registry.close
    end

    assert_equal({"Authorization" => "Bearer token"}, options.fetch(:headers))
  end

  def test_toolset_exposes_every_server_tool_when_expose_is_omitted
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        @payloads << payload
        {"result" => {"tools" => [
          {"name" => "search", "description" => "Search"},
          {"name" => "fetch", "description" => "Fetch"}
        ]}}
      end
    end.new
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
    end

    LittleGhost::MCP::HTTPTransport.stub(:new, transport) do
      registry = LittleGhost::ToolRegistry.new([toolset])
      assert_equal %w[search fetch], registry.names
    ensure
      registry&.close
    end
  end

  def test_toolset_configuration_is_inherited_and_validated
    parent = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
      prefix "shared"
      expose "search"
    end
    child = Class.new(parent)

    assert_equal parent.endpoint, child.endpoint
    assert_equal parent.prefix, child.prefix
    assert_equal parent.expose, child.expose

    error = assert_raises(LittleGhost::ConfigurationError) do
      Class.new(LittleGhost::MCP::Toolset).tools(LittleGhost::Tool::Binding.new)
    end
    assert_includes error.message, "must declare an MCP endpoint"

    invalid_headers = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
      headers { "not a hash" }
    end
    error = assert_raises(LittleGhost::ConfigurationError) do
      invalid_headers.tools(LittleGhost::Tool::Binding.new)
    end
    assert_includes error.message, "headers must resolve to a hash"
  end

  def test_toolset_requires_headers_to_be_redeclared_for_a_different_endpoint
    parent = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://first.example/rpc"
      headers "Authorization" => "Bearer first"
    end
    child = Class.new(parent) do
      endpoint "https://second.example/rpc"
    end

    error = assert_raises(LittleGhost::ConfigurationError) do
      child.tools(LittleGhost::Tool::Binding.new)
    end
    assert_includes error.message, "redeclare headers"

    child.headers({})
    options = nil
    factory = lambda do |**values|
      options = values
      Transport.new
    end
    LittleGhost::MCP::HTTPTransport.stub(:new, factory) do
      registry = LittleGhost::ToolRegistry.new([child])
      registry.close
    end
    assert_equal "https://second.example/rpc", options.fetch(:url)
    assert_empty options.fetch(:headers)
  end

  def test_toolset_copies_and_freezes_static_headers
    name = +"Authorization"
    value = +"Bearer first"
    configured = {name => value}
    toolset = Class.new(LittleGhost::MCP::Toolset) do
      endpoint "https://mcp.example/rpc"
      headers configured
    end

    name.replace("Changed")
    value.replace("Bearer changed")
    configured.clear

    assert_equal({"Authorization" => "Bearer first"}, toolset.headers)
    assert toolset.headers.frozen?
    assert toolset.headers.keys.first.frozen?
    assert toolset.headers.values.first.frozen?
  end

  def test_concurrent_tool_discovery_initializes_the_protocol_once
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

    methods = transport.payloads.map { |payload| payload[:method] }
    assert_equal 1, methods.count("initialize")
    assert_equal 1, methods.count("notifications/initialized")
  end

  def test_generated_tools_forward_the_run_context
    transport = Transport.new
    tool = LittleGhost::MCP::Client.new(transport:).tools.first.new
    context = LittleGhost::RunContext.new

    result = tool.execute({"query" => "ruby"}, context:)

    assert result.success?
    assert_same context, transport.contexts.last
  end

  def test_http_transport_cancellation_interrupts_a_stalled_request
    token = LittleGhost::Support::CancellationToken.new
    server, socket, runner = stalled_request(context: LittleGhost::RunContext.new(cancellation_token: token))

    token.cancel

    assert runner.join(1), "stalled MCP request did not stop after cancellation"
    assert_instance_of LittleGhost::CancelledError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
    socket&.close
    server&.close
  end

  def test_http_transport_deadline_interrupts_a_stalled_request
    context = LittleGhost::RunContext.new(deadline: Time.now + 0.05)
    server, socket, runner = stalled_request(context:)

    assert runner.join(1), "stalled MCP request did not stop at its deadline"
    assert_instance_of LittleGhost::DeadlineExceededError, runner.value
  ensure
    context&.cancellation_token&.cancel
    runner&.kill
    runner&.join
    socket&.close
    server&.close
  end

  def test_executor_does_not_wait_for_a_stalled_generated_mcp_tool_after_cancellation
    token = LittleGhost::Support::CancellationToken.new
    context = LittleGhost::RunContext.new(cancellation_token: token)
    server = TCPServer.new("127.0.0.1", 0)
    http = LittleGhost::MCP::HTTPTransport.new(
      url: "http://127.0.0.1:#{server.local_address.ip_port}",
      timeout: 60,
      allow_insecure_http: true
    )
    transport = Transport.new
    transport.define_singleton_method(:send) do |payload, context: nil|
      if payload[:method] == "tools/call"
        http.send(payload, context:)
      else
        super(payload, context:)
      end
    end
    tool = LittleGhost::MCP::Client.new(transport:).tools.first.new
    runner = Thread.new do
      LittleGhost::Support::Executor.new.map([tool], cancellation_token: token) do |candidate|
        candidate.execute({}, context:)
      end
    rescue => error
      error
    end
    runner.report_on_exception = false
    socket = server.accept

    token.cancel

    assert runner.join(1), "executor waited for a cancelled MCP call"
    assert_instance_of LittleGhost::CancelledError, runner.value
  ensure
    token&.cancel
    runner&.kill
    runner&.join
    socket&.close
    server&.close
  end

  def test_aliases_tool_names_longer_than_model_limit
    client = LittleGhost::MCP::Client.new(transport: Transport.new(tool_name: "a" * 100))

    name = client.tools.first.tool_name

    assert_equal 64, name.length
    assert_match(/_[a-f0-9]{12}\z/, name)
  end

  def test_rejects_filtered_tools
    client = LittleGhost::MCP::Client.new(transport: Transport.new, rejected_tools: ["search"])

    assert_empty client.tools
  end

  def test_filters_raw_tool_definitions_before_building_tools
    definitions = [
      {
        "name" => "read",
        "description" => "Read",
        "inputSchema" => {"type" => "object"},
        "annotations" => {"readOnlyHint" => true}
      },
      {
        "name" => "write",
        "description" => "Write",
        "inputSchema" => {"type" => "object"},
        "annotations" => {"readOnlyHint" => false}
      }
    ]
    transport = Class.new(Transport) do
      define_method(:send) do |payload, context: nil|
        return super(payload, context:) unless payload[:method] == "tools/list"

        {"result" => {"tools" => definitions}}
      end
    end.new
    seen = []
    client = LittleGhost::MCP::Client.new(
      transport:,
      definition_filter: ->(definition) {
        seen << definition.fetch("name")
        definition.dig("annotations", "readOnlyHint") == true
      }
    )

    assert_equal ["read"], client.tools.map(&:tool_name)
    assert_equal %w[read write], seen
  end

  def test_rejects_invalid_definition_filter
    error = assert_raises(ArgumentError) do
      LittleGhost::MCP::Client.new(transport: Transport.new, definition_filter: true)
    end

    assert_equal "definition_filter must respond to call", error.message
  end

  def test_loads_all_pages_of_tools
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        @payloads << payload
        if payload[:params].empty?
          {"result" => {"tools" => [{"name" => "first", "description" => "First"}], "nextCursor" => "page-2"}}
        else
          {"result" => {"tools" => [{"name" => "second", "description" => "Second"}]}}
        end
      end
    end.new

    client = LittleGhost::MCP::Client.new(transport: transport)

    assert_equal %w[first second], client.tools.map(&:tool_name)
    assert_equal [{}, {cursor: "page-2"}], transport.payloads.filter_map { |payload| payload[:params] if payload[:method] == "tools/list" }
  end

  def test_raises_when_tool_result_reports_an_error
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/call"

        @payloads << payload
        {"result" => {"content" => [{"type" => "text", "text" => "permission denied"}], "isError" => true}}
      end
    end.new
    tool = LittleGhost::MCP::Client.new(transport: transport).tools.first.new

    result = tool.execute({"query" => "ruby"})

    assert result.error?
    assert_equal "permission denied", result.content
  end

  def test_preserves_structured_content_with_and_without_text_content
    responses = [
      {
        "content" => [{"type" => "text", "text" => "found"}],
        "structuredContent" => {"items" => [1]}
      },
      {"structuredContent" => {"items" => [2]}}
    ]
    transport = Class.new(Transport) do
      define_method(:send) do |payload, context: nil|
        return super(payload) unless payload[:method] == "tools/call"

        @payloads << payload
        {"result" => responses.shift}
      end
    end.new
    tool_class = LittleGhost::MCP::Client.new(transport: transport).tools.first

    with_text = JSON.parse(tool_class.new.execute({}).content)
    structured_only = JSON.parse(tool_class.new.execute({}).content)

    assert_equal({"items" => [1]}, with_text.fetch("structuredContent"))
    assert_equal "found", with_text.fetch("content").first.fetch("text")
    assert_equal({"structuredContent" => {"items" => [2]}}, structured_only)
  end

  def test_rejects_non_object_structured_content
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/call"

        {"result" => {"structuredContent" => ["invalid"]}}
      end
    end.new
    tool = LittleGhost::MCP::Client.new(transport: transport).tools.first.new

    result = tool.execute({})

    assert result.error?
    assert_includes result.content, "ProtocolError"
  end

  def test_rejects_repeated_pagination_cursors
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        @payloads << payload
        {"result" => {"tools" => [], "nextCursor" => "same"}}
      end
    end.new

    error = assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: transport).tools
    end

    assert_includes error.message, "repeated"
  end

  def test_normalizes_provider_unsafe_names_and_missing_descriptions
    transport = Transport.new(tool_name: "search.web")

    tool = LittleGhost::MCP::Client.new(transport: transport, prefix: "company tools").tools.first

    assert_equal "company_tools___search_web", tool.tool_name
    assert_equal "Search", tool.description
  end

  def test_rejects_mismatched_response_ids
    transport = Class.new(Transport) do
      def send(payload, context: nil)
        response = super
        response["id"] = 999 if payload[:method] == "initialize"
        response
      end
    end.new

    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: transport).tools
    end
  end

  def test_bounds_tools_and_pagination
    assert_raises(ArgumentError) do
      LittleGhost::MCP::Client.new(transport: Transport.new, max_tools: 0)
    end

    transport = Class.new(Transport) do
      def send(payload, context: nil)
        return super unless payload[:method] == "tools/list"

        {"result" => {"tools" => [], "nextCursor" => SecureRandom.hex(4)}}
      end
    end.new
    assert_raises(LittleGhost::ProtocolError) do
      LittleGhost::MCP::Client.new(transport: transport, max_pages: 1).tools
    end
  end

  def test_malformed_response_shapes_raise_protocol_errors
    missing_result = Class.new(Transport) do
      def send(payload, context: nil)
        return {} if payload[:method] == "initialize"

        super
      end
    end.new
    malformed_tools = Class.new(Transport) do
      def send(payload, context: nil)
        return {"result" => {"tools" => "invalid"}} if payload[:method] == "tools/list"

        super
      end
    end.new
    missing_name = Class.new(Transport) do
      def send(payload, context: nil)
        return {"result" => {"tools" => [{}]}} if payload[:method] == "tools/list"

        super
      end
    end.new

    [missing_result, malformed_tools, missing_name].each do |transport|
      assert_raises(LittleGhost::ProtocolError) do
        LittleGhost::MCP::Client.new(transport:).tools
      end
    end
  end

  private

  def stalled_request(context:)
    server = TCPServer.new("127.0.0.1", 0)
    transport = LittleGhost::MCP::HTTPTransport.new(
      url: "http://127.0.0.1:#{server.local_address.ip_port}",
      timeout: 60,
      allow_insecure_http: true
    )
    runner = Thread.new do
      transport.send({jsonrpc: "2.0", id: 1, method: "tools/list", params: {}}, context:)
    rescue => error
      error
    end
    runner.report_on_exception = false
    socket = server.accept
    [server, socket, runner]
  end
end
