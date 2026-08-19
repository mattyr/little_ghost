# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost can load Tools from an MCP server, translate a Run stream for an
interactive interface, and publish lifecycle traces. Each integration uses the
same Agents and Runs you already have.

## Load Tools from an MCP server

Declare a reusable set of remote Tools, then add it to an Agent with the same
`tools` DSL used for Ruby Tools:

```ruby
require "little_ghost/mcp"

class HelpCenterTools < LittleGhost::MCP::Toolset
  endpoint "https://mcp.example/rpc", timeout: 20
  headers { {"Authorization" => "Bearer #{ENV.fetch("MCP_ACCESS_TOKEN")}"} }
  prefix "help_center"
  expose "search", "fetch"
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
  tools HelpCenterTools
end

run = CustomerSupportAgent.ask("What is the return window?")
```

`HelpCenterTools` is reusable configuration. Each Agent gets its own MCP Client
and negotiated session when LittleGhost materializes the Toolset. `prefix` keeps
the model-visible names distinct, and `expose` loads only the operations this
Agent needs. Omit `expose` when the Agent should receive every valid Tool the
server advertises.

`HTTPTransport` uses HTTPS by default, limits response time and size, and keeps
the negotiated MCP session ID. The `headers` block runs as each Agent is built.
It may accept the current Run when credentials depend on the authenticated
caller:

```ruby
class HelpCenterTools < LittleGhost::MCP::Toolset
  endpoint "https://mcp.example/rpc", timeout: 20
  headers do |run|
    token = McpAccessTokens.for_actor(run.invocation.actor_id)
    {"Authorization" => "Bearer #{token}"}
  end
  prefix "help_center"
  expose "search", "fetch"
end

CustomerSupportAgent.ask(
  "What is the return window?",
  actor_id: authenticated_user.id
)
```

Here, `McpAccessTokens` is an application service that returns a token for the
authenticated actor.

> **Safety note:** An MCP server chooses its Tool definitions and results. Load
> only the operations your application intends to expose. The server must check
> caller and resource access using the credentials sent with each request;
> `expose` limits which operations are loaded, but does not authorize them.

LittleGhost implements its documented client behavior for the [MCP 2025-06-18
specification](https://modelcontextprotocol.io/specification/2025-06-18). The
API reference covers supported protocol options and limits.

Use `LittleGhost::MCP::HTTPTransport` and `LittleGhost::MCP::Client` directly
when you need a custom transport or want to inspect each server definition with
a custom filter.

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
