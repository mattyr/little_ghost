# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost can load Tools from an MCP server, translate a Run stream for an
interactive interface, and publish lifecycle traces. Each integration uses the
same Agents and Runs you already have.

## Load Tools from an MCP server

Declare a reusable remote Toolset and add it through the ordinary Agent `tools`
DSL:

```ruby
require "little_ghost/mcp"

class HelpCenterTools < LittleGhost::MCP::Toolset
  connection do |binding|
    token = McpAccessTokens.for_actor(binding.run.invocation.actor_id)
    {
      url: "https://mcp.example/rpc",
      headers: {"Authorization" => "Bearer #{token}"},
      timeout: 20
    }
  end

  map_tool do |tool_class, definition:, binding:|
    next unless %w[search fetch].include?(definition.source_name)

    tool_class.tool_name "help_center_#{definition.source_name}"
    tool_class
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
  tools HelpCenterTools
end
```

LittleGhost resolves `connection` for each `Tool::Binding`, creates a fresh
HTTP transport and Client, and negotiates one server session. The connection
Hash requires `url` and may include `headers`, `timeout`, `signer`,
`allow_insecure_http`, and `max_response_bytes`.

`map_tool` is the single definition extension point. It receives a generated
ordinary Tool class plus immutable `definition:` and current `binding:`.
Return the class after configuring its name, description, schema, or exclusivity;
return `nil` to omit it. Renaming never changes `Definition#source_name`,
which is always sent back to the server.

Map selected results without reimplementing the defaults:

```ruby
map_result do |result, call:, binding:|
  next result unless call.definition.source_name == "export"

  LittleGhost::Tool::Result.new(
    value: result.structured_content,
    artifacts: [
      LittleGhost::Artifact.deferred(
        reference: result.metadata.fetch("download_id"),
        media_type: "application/octet-stream"
      )
    ]
  )
end
```

`map_result` receives immutable `MCP::Result` and `MCP::Call` values plus
the binding. Return any Ruby value or `Tool::Result`. Returning the supplied
MCP result unchanged applies LittleGhost's default conversion: structured
content becomes the machine value when present, otherwise text does. MCP images
become Artifacts and follow the same configured lifecycle as local Tool media.
Advertised output schemas are validated as JSON Schema Draft 2020-12.

An optional server can fail discovery without preventing Agent construction:

```ruby
class HelpCenterTools < LittleGhost::MCP::Toolset
  connection { |binding| McpConnections.help_center(binding) }
  optional true
  on_error do |error, binding:|
    McpAvailability.report(error, run_id: binding.run.invocation.run_id)
  end
end
```

`optional true` converts expected provider and protocol discovery failures
into an empty Tool set. `on_error` observes only those caught failures.
Cancellation, deadlines, configuration errors, and application callback
failures still propagate.

Discovery size, definition complexity, output-schema evaluation, and MCP media
use fixed defensive framework limits. `HTTPTransport` separately bounds each
wire response and requires HTTPS unless explicitly configured for local HTTP.

> **Safety note:** An MCP server chooses its Tool definitions and results. Map
> only the operations your application intends to expose. The server must still
> authorize each operation from the credentials sent with the request.

LittleGhost implements its documented client behavior for the [MCP 2025-06-18
specification](https://modelcontextprotocol.io/specification/2025-06-18).

Use `LittleGhost::MCP::HTTPTransport` and `LittleGhost::MCP::Client` directly
when you need a custom transport while retaining the same generated Tool and
result-mapping contracts.


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
