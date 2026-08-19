# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost's integration layers connect the same Agent and Run lifecycle to
remote Tools, interactive interfaces, and tracing systems. Each one crosses a
different trust boundary; enable only the data flow the application needs.

## Use MCP Tools through one trusted client

Load the optional MCP integration and connect to a Streamable HTTP endpoint:

```ruby
require "little_ghost/mcp"

transport = LittleGhost::MCP::HTTPTransport.new(
  url: "https://mcp.example/rpc",
  headers: {
    "Authorization" => "Bearer #{ENV.fetch("MCP_ACCESS_TOKEN")}"
  },
  timeout: 20,
  max_response_bytes: 2 * 1024 * 1024
)

client = LittleGhost::MCP::Client.new(
  transport:,
  prefix: "help_center",
  rejected_tools: %w[delete_article],
  definition_filter: ->(definition) {
    %w[search fetch].include?(definition.fetch("name"))
  }
)

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published policy facts."
end

CustomerSupportAgent.tools(*client.tools)
run = CustomerSupportAgent.ask("What is the return window?")
```

`HTTPTransport` requires HTTPS unless trusted local development explicitly sets
`allow_insecure_http: true`. It bounds request time and response bytes, accepts
JSON or server-sent event responses, and retains the negotiated MCP session ID.
The Client negotiates protocol version `2025-06-18`, paginates tool definitions,
normalizes names, checks collisions, and turns accepted definitions into
ordinary `LittleGhost::Tool` instances.

The wire behavior follows the [MCP 2025-06-18
specification](https://modelcontextprotocol.io/specification/2025-06-18).
LittleGhost currently implements the client behavior described by its API; do
not infer support for every optional protocol capability from the specification.

MCP definitions, schemas, results, and error messages remain untrusted server
input. Use `rejected_tools` or `definition_filter` as an application allowlist,
then apply normal authorization to every resulting capability. Prefixes prevent
accidental name overlap; they do not create a security boundary.

One transport and Client represent one authenticated server session. Do not
share the pair across tenants or principals. Scope credential headers to that
server, set bounded response and pagination limits, and configure server-side
session expiry when explicit termination is required. LittleGhost does not send
an MCP session-termination `DELETE` request.

## Translate a stream to AG-UI

The AG-UI adapter converts LittleGhost events into protocol event hashes:

```ruby
require "json"
require "little_ghost/ag_ui"

source = CustomerSupportAgent.stream_ask(
  question,
  actor_id: authenticated_user.id,
  context: {account_id: authenticated_user.account_id}
)

events = LittleGhost::AGUI::Adapter.new.stream(
  source,
  thread_id: conversation.id,
  run_id: request.request_id
)

events.each { |event| websocket.write(JSON.generate(event)) }
```

The adapter is stateless between calls and translates text, reasoning, Tool
activity, usage, retries, trace context, subagent events, and terminal outcomes.
It does not authenticate the client, persist a thread, control backpressure, or
redact the stream.

Use the [AG-UI event documentation](https://docs.ag-ui.com/concepts/events) when
implementing the consumer. LittleGhost also emits namespaced custom events, so
clients must preserve or deliberately ignore event types they do not recognize.

Provider plaintext reasoning, Tool arguments and results, selected error text,
invocation metadata, trace context, and subagent data may reach the interface.
Authorize the user for the complete run, filter fields before transport, apply
message and rate limits, and use an authenticated encrypted channel. Never use
an AG-UI `thread_id` as proof of identity or tenant membership.

The source stream runs on the enumerating thread. Handle disconnects by ending
enumeration and applying the application's cancellation policy; closing a
socket alone does not undo Tool side effects already performed.

## Export lifecycle spans with OpenTelemetry

LittleGhost includes an OpenTelemetry subscriber. Configure an OpenTelemetry
SDK and exporter in the application, then register the subscriber before the
first Agent call:

```ruby
LittleGhost.configure do |config|
  config.instrument LittleGhost::Tracing::OpenTelemetry.new
end
```

LittleGhost depends on `opentelemetry-api`, not a particular SDK, processor, or
exporter. The subscriber emits GenAI-oriented spans and events for runs, Agents,
model calls, Tools, assemblies, sessions, usage, and failures. It can propagate
W3C `traceparent` and `tracestate` fields for active operations.

Attribute names follow the evolving [OpenTelemetry GenAI semantic
conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) where they
apply. Treat dashboards and alerts as versioned integrations rather than
assuming every backend interprets those attributes identically.

Prompts, messages, responses, Tool arguments, and exception content are omitted
by default. They appear only when the process installs an explicit
`LittleGhost::Support::ContentCapture` policy. Keep capture disabled unless the
application has a reviewed scrubber, retention policy, access controls, and an
export destination approved for that data.

Avoid high-cardinality attributes such as raw user, order, session, or request
IDs. A telemetry exporter is an external data recipient; its endpoint,
credentials, sampling, retention, and regional behavior need the same review as
a model provider. Flush or shut down `LittleGhost::Instrumentation` during
application shutdown when the configured backend buffers data.

## Keep the boundaries independent

These integrations do not implicitly protect one another:

```text
MCP server ──untrusted tools and results──> trusted Tool boundary
Run stream ──potentially sensitive events──> authorized AG-UI client
Lifecycle ──selected attributes and content──> telemetry backend
```

A Sandbox policy does not contain the MCP HTTP request, AG-UI transport, or
telemetry exporter; they run through trusted application code. Conversely,
using HTTPS does not authorize an MCP Tool, sanitize an AG-UI event, or make
telemetry safe to retain.

Test each integration at its protocol boundary: reject disallowed MCP
definitions and oversized responses, verify every AG-UI terminal and failure
path, and inspect exported spans with content capture both disabled and scrubbed.

See [Tools](tools.md) for application authority, [Running in
Production](production.md) for lifecycle and observability, and [Workspaces and
Sandboxes](sandboxing.md) for the operations that actually cross an enforced
process boundary.
