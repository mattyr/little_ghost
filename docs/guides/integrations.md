# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost can load Tools from an MCP server, translate a Run stream for an
interactive interface, and publish lifecycle traces. Each integration uses the
same Agents and Runs you already have.

## Load Tools from an MCP server

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
  definition_filter: ->(definition) {
    %w[search fetch].include?(definition.fetch("name"))
  }
)

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
end

CustomerSupportAgent.tools(*client.tools)
run = CustomerSupportAgent.ask("What is the return window?")
```

The Client loads accepted definitions and turns them into ordinary
`LittleGhost::Tool` instances. `prefix` keeps their model-visible names distinct,
and `definition_filter` lets this Agent load only the operations it needs.

`HTTPTransport` uses HTTPS by default, limits response time and size, and keeps
the negotiated MCP session ID. One transport and Client pair represents one
authenticated server session, so create separate pairs when callers use
different server credentials.

> **Safety note:** An MCP server chooses its Tool definitions and results. Load
> only the operations your application intends to expose. The server must check
> caller and resource access using the credentials or session attached to this
> Client; `definition_filter` limits which operations are loaded, but does not
> authorize them. Use a separate Client when callers need different access.

LittleGhost implements its documented client behavior for the [MCP 2025-06-18
specification](https://modelcontextprotocol.io/specification/2025-06-18). The
API reference covers supported protocol options and limits.

## Send a Run stream through AG-UI

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

The adapter translates text, reasoning, Tool activity, usage, retries, trace
context, subagent activity, and terminal outcomes. It is stateless between
calls. Your application still owns the connection, thread storage,
backpressure, and disconnect behavior.

LittleGhost also emits namespaced custom events. Consumers should preserve or
deliberately ignore event types they don't recognize. See the [AG-UI event
documentation](https://docs.ag-ui.com/concepts/events) when implementing the
client.

> **Safety note:** A Run stream can include model output, Tool arguments and
> results, errors, and participant activity. Check that the connected user may
> see the complete Run, then filter fields before sending or storing events.

Enumeration drives the source stream on the current thread. When a client
disconnects, stop enumerating and apply the cancellation behavior your
application needs. Closing the socket can't undo Tool work that already ran.

## Trace Runs with OpenTelemetry

Configure an OpenTelemetry SDK and exporter in the application, then register
the LittleGhost subscriber before the first Agent call:

```ruby
LittleGhost.configure do |config|
  config.instrument LittleGhost::Tracing::OpenTelemetry.new
end
```

LittleGhost depends on `opentelemetry-api`, leaving the SDK, processor, and
exporter up to the application. It emits spans and events for Runs, Agents,
model calls, Tools, assemblies, sessions, usage, and failures. Active operations
can propagate W3C `traceparent` and `tracestate` fields.

Prompts, messages, responses, Tool arguments, and exception content are omitted
by default. If you intentionally need some of that content, install a
`LittleGhost::Support::ContentCapture` with a scrubber before enabling capture.
Avoid putting raw user, order, session, or request IDs in span attributes.

Attribute names follow the evolving [OpenTelemetry GenAI semantic
conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) where they
apply. Flush or shut down `LittleGhost::Instrumentation` during application
shutdown when your backend buffers data.

See [Running in Production](production.md) for lifecycle and observability,
[Tools](tools.md) for local and remote Tool behavior, and [Workspaces and
Sandboxes](sandboxing.md) for child processes and files.
