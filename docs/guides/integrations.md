# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost can load Tools from an MCP server, translate a Run stream for an
interactive interface, and publish traces. Each integration uses the same
Agents and Runs you already have.

## Load Tools from an MCP server

An MCP Toolset connects to one server and turns its published operations into
LittleGhost Tool classes. Add the Toolset through the same Agent `tools`
declaration used for local Tools:

```ruby
require "little_ghost/mcp"

class HelpCenterTools < LittleGhost::MCP::Toolset
  connection url: "https://mcp.example/rpc", timeout: 20
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
  tools HelpCenterTools
end

run = CustomerSupportAgent.ask("How long do refunds take?")
run.response
```

`connection` requires `url` and also accepts `headers`, `timeout`, `signer`,
`allow_insecure_http`, and `max_response_bytes`. Pass a block when credentials
depend on the current Agent run:

```ruby
connection do |binding|
  token = McpAccessTokens.for_actor(binding.run.invocation.actor_id)
  {
    url: "https://mcp.example/rpc",
    headers: {"Authorization" => "Bearer #{token}"},
    timeout: 20
  }
end
```

The block's `binding` gives it access to the current Run. LittleGhost evaluates
the block before opening the MCP session, so each Agent run can use credentials
for its authenticated caller.

By default, the Agent receives every operation published by the server. Their
normalized server names, such as `search` and `fetch`, become Tool names.

Use `map_tool` when the Agent should receive only part of the server catalog or
when a generated Tool needs a different name or configuration:

```ruby
class CuratedHelpCenterTools < LittleGhost::MCP::Toolset
  connection url: "https://mcp.example/rpc", timeout: 20

  map_tool do |tool_class, definition:, binding:|
    next unless %w[search fetch].include?(definition.source_name)

    tool_class.tool_name "help_center_#{definition.source_name}"
    tool_class
  end
end
```

`definition` describes the operation published by the server, and `binding`
identifies the current Agent run. Return the class after configuring it, or
return `nil` to omit the operation. Renaming a generated Tool does not change
the original `Definition#source_name` sent back to the server.

The Agent can call the generated Tools like local Tools. LittleGhost uses one
local client and transport for the Toolset during the Agent run. The built-in
HTTP transport does not send an MCP session-termination request. Configure
server-side expiry, or arrange explicit remote cleanup when the server requires
it.

Most MCP results need no mapping. LittleGhost returns `structuredContent` as a
Ruby Hash when present, otherwise it returns the server's text. Server images
become Artifacts.

Use `map_result` when one operation needs application-specific conversion. This
example turns the server's download identifier into a deferred Artifact:

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

`map_result` receives the complete `MCP::Result`, the `MCP::Call` that produced
it, and the current binding. Return any Ruby value or `Tool::Result`. Returning
the supplied result unchanged keeps the default conversion described above.
MCP images and local Tool artifacts use the same storage and presentation
rules when `Configuration#artifacts` is enabled. LittleGhost also checks results
against server-advertised JSON Schema Draft 2020-12 output schemas.

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

LittleGhost limits the number and total size of discovered operations, the
complexity of their schemas, and the size and number of returned images.
`HTTPTransport` also limits each HTTP response and requires HTTPS unless local
HTTP is explicitly enabled.

> **Safety note:** An MCP server supplies descriptions and results that the model
> can see. Structural validation does not make that content trustworthy or
> authorize an operation it suggests. Expose only the operations the Agent
> needs, use narrowly scoped credentials, and have the server authorize every
> sensitive call. If a result becomes a deferred Artifact, its resolver must
> verify that the referenced file belongs to the authenticated caller, fetch
> only from an intended service, and limit the response size before returning
> bytes to LittleGhost.

LittleGhost implements its documented client behavior for the [MCP 2025-06-18
specification](https://modelcontextprotocol.io/specification/2025-06-18).

Use `LittleGhost::MCP::HTTPTransport` and `LittleGhost::MCP::Client` directly
when you need a custom transport. They produce the same generated Tool classes
and accept the same mapping callbacks as Toolset.

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

See [Running in Production](production.md) for startup, shutdown, and observability,
[Tools](tools.md) for local and remote Tool behavior, and [Workspaces and
Sandboxes](sandboxing.md) for child processes and files.
