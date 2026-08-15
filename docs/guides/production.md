# Running in Production

The Agent or Assembly you ran in a script can move into a controller, job, CLI, or service without changing shape. A long-running application usually adds stable model names, shared services, conversation history, background execution, and observability.

## Select models by application role

A direct target keeps a small definition self-contained:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
end
```

As an application grows, a **model role** gives that choice a stable application name:

```ruby
# config/initializers/little_ghost.rb
LittleGhost.configure do |config|
  config.providers = {
    openrouter: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY")
    }
  }
  config.models = {
    customer_support: {
      target: "openrouter:openai/gpt-5.6-luna",
      settings: {temperature: 0.2}
    }
  }
  config.default_model = :customer_support
end

class CustomerSupportAgent < LittleGhost::Agent
  model :customer_support
end
```

Provider connections and model roles can also live in YAML files under `config/little_ghost`, or in files you select explicitly. Values set in Ruby take priority. An explicitly selected file comes next, followed by conventional files and environment defaults. See `LittleGhost::Configuration` when you need every supported source and override.

Prompts, caller input and history, tool results, and attachments may leave the application for the selected external provider. Select providers from trusted configuration and account for their retention and data-residency policies.

## Configure once, call from anywhere

The `LittleGhost.configure` block above is the entire initializer. Controllers and jobs can call your Agent and Assembly classes directly.

Then call the Agent directly from a controller or job:

```ruby
class SupportQuestionsController < ApplicationController
  def create
    run = CustomerSupportAgent.ask(
      params.require(:question),
      actor_id: current_user.id,
      context: {account_id: current_user.account_id}
    )

    if run.completed?
      render json: {answer: run.response}
    else
      render json: {error: "Support request failed"}, status: :bad_gateway
    end
  end
end
```

On the first class-level call, LittleGhost prepares model resolution, loading, prompt lookup, persistence, hooks, and factories. Later calls reuse those application services automatically.

Each `.ask` creates a fresh top-level Run with fresh bound participants and Tools. Reusing application services does not create conversation history. Pass a stable `session_id` only when a later request should continue an earlier conversation.

The controller supplies identity and account access from authenticated application state. The model cannot replace those values through its prompt or tool arguments. A background job uses the same direct calling style.

Configure LittleGhost before the first Agent or Assembly call. Once application services start successfully, the configuration is locked so every request sees one stable setup.

## Preserve conversation with Sessions

A **Session** lets one request continue an earlier conversation. Pass the same session ID and trusted actor ID with each related call:

```ruby
run = CustomerSupportAgent.ask(
  "What did we decide about my refund?",
  session_id: "conversation-42",
  actor_id: authenticated_user.id
)
```

Take `actor_id` from authenticated application state. A session ID alone does not prove who the caller is, and a nil actor does not separate tenants. Built-in persistence drops system messages, temporary messages, and private reasoning. If you customize persistence, decide what else is safe to store.

A session is checkpointed when its store write succeeds. The in-memory store lasts only as long as one process. Choose a durable `SessionStore` when conversations must survive a restart or continue on another process.

{LittleGhost::SessionStores::Filesystem}[rdoc-ref:LittleGhost::SessionStores::Filesystem] is a built-in durable choice for a trusted local or shared filesystem. Set its root to the application-managed directory that holds session data:

```ruby
LittleGhost.configure do |config|
  config.session_store = {
    provider: LittleGhost::SessionStores::Filesystem,
    root: "/var/lib/customer_support/sessions"
  }
end
```

Every Run has a session ID so LittleGhost can checkpoint its progress. If you do not supply one, LittleGhost generates a new ID for that call. Because your application does not reuse that generated ID, it does not create conversation continuity. A persistent SessionStore may still save working state under it before the Run finishes, so keep request context safe to store or filter sensitive fields in your store.

## Stream or supervise long-running work

`.stream_ask` runs on the caller's thread and yields `StreamEvent` values as the answer arrives:

```ruby
stream = CustomerSupportAgent.stream_ask(question)

run = stream.each do |event|
  publish(event) if event.type == :text_delta
end

record_outcome(run.outcome, error_type: run.error&.class&.name)
```

Use `start_execution` when the caller must stay free for other work, or when you want to deliver an interjection to an active response:

```ruby
execution = agent.start_execution(message: question) do |event|
  event_buffer << event
end

execution.interject(message: "Include the latest ledger entry")
execution.wait(deadline: Time.now + 30)
execution.run.completed?
```

The event block runs on the worker thread, so keep it quick. Cancellation, deadlines, and `close` ask the work to stop; they cannot forcibly end arbitrary provider or tool code. They also cannot undo actions that already happened.

## Treat tools as application boundaries

A tool schema checks the shape of model-supplied input. Your application still owns permission checks, safe retries, rate limits, tenant boundaries, and auditing.

Use the Tool binding's `run` to read current, application-established values from `run.invocation.context`. Do not make permission decisions from model arguments.

Treat `RunContext#state` as mutable working and Session state. Revalidate anything restored from an earlier request. Synchronize access when parallel Tools share mutable state, or mark every Tool that reads or changes it as `exclusive true`.

A `ToolError` message is visible to the model, so keep it safe to share. LittleGhost hides unexpected exception messages from model-facing results.

When a step retries, its tool calls may happen again too. Prefer read-only work, idempotency keys, or operations that are safe to repeat.

## Choose workspace and sandbox behavior explicitly

A **Workspace** is the host directory owned by one Run. It answers where Run files persist. A **Sandbox** maps that directory and any additional mounts into a filesystem view, applies process and network policy, and answers how commands run. A **Tool** remains application code: built-in filesystem and shell tools use the bound Sandbox, while a custom Ruby Tool runs in the application process unless it deliberately delegates work to `sandbox` or a narrowed `sandbox.scope`.

The default is deliberately compatible and dependency-free: an application-root Workspace with `LittleGhost::Sandboxes::Unrestricted`. It uses the host process's permissions and inherited networking, so it is not an isolation boundary. Selecting an enforcing backend is always explicit and never silently falls back:

```ruby
LittleGhost.configure do |config|
  config.workspace = {provider: :directory, root: "/var/lib/my_agent/work"}
  config.sandbox = {
    provider: :docker,
    image: "my-agent-runtime@sha256:...",
    workspace_path: "/workspace",
    workspace_access: :read_write,
    root_filesystem: :read_only,
    environment: {inherit: false, set: {"LANG" => "C.UTF-8"}},
    network: :none,
    execution_scope: :command
  }
end
```

Use named paths and lifecycle callbacks when a run needs more than one
application-owned directory. This remains configuration; it does not require a
Workspace subclass:

```ruby
config.workspace = lambda do
  root = File.join("/var/lib/my_agent/runs", SecureRandom.uuid)
  cache = File.join(root, ".cache")
  LittleGhost::Workspace.new(
    root:,
    paths: {cache:},
    setup: ->(workspace:, **) { FileUtils.mkdir_p(workspace.path(:cache)) },
    teardown: ->(workspace:, **) { FileUtils.remove_entry_secure(workspace.root) }
  )
end
```

The built-in providers have distinct dependency and lifecycle tradeoffs:

| Provider | Platforms | Dependency | Isolation | Lifecycles |
| --- | --- | --- | --- | --- |
| `:unrestricted` | Ruby platforms | none | host process permissions | Run-owned object |
| `:bubblewrap` | Linux | `bwrap`; `socat` for filtered egress | user, PID, mount, IPC, UTS, cgroup, and optional network namespaces | fresh namespace per command |
| `:docker` | macOS and Linux | reachable Docker daemon and an application-selected image | container filesystem and network | fresh container per command or one container per Sandbox |

`execution_scope: :command` starts with a clean process environment for each command. `execution_scope: :sandbox` preserves one Docker container until the Sandbox closes, which is useful when process-visible state must survive between commands. Bubblewrap is command-scoped. Files in writable mounts persist in either mode; process state and unmounted root-filesystem changes do not persist across command-scoped executions.

Mounts are explicit virtual mappings. By default, the same mount is available to isolated processes and direct filesystem tools. Set `tools: false` for process-only runtime, service-socket, cache, or home mounts that filesystem tools must not traverse. A Scope can only remove capabilities, narrow a mount to a descendant, or make writable access read-only; it cannot widen its parent Sandbox. This makes one parent policy reusable by Tools with different least-privilege views:

```ruby
read_reports = run.sandbox.scope(
  mounts: [{target: "/workspace/reports", access: :read_only}],
  capabilities: LittleGhost::Sandbox::Capabilities.new(
    features: %i[filesystem_read filesystem_list]
  )
)
```

Applications with repeatable tool roles can name those views in configuration instead of defining a Sandbox subclass. A profile may narrow mounts, capabilities, and an allowlisted network to `:none`:

```ruby
config.sandbox = lambda do |workspace:, **|
  LittleGhost::Sandboxes::Bubblewrap.new(
    workspace:,
    policy: {
      workspace_access: :read_write,
      mounts: [{source: "/srv/reference", target: "/reference"}],
      network: {mode: :allowlist, allow: ["api.example.com:443"]}
    },
    profiles: {
      developer: {mounts: ["/workspace", "/reference"], network: true},
      reviewer: {
        mounts: [{target: "/workspace", access: :read_only}, "/reference"],
        network: false
      }
    }
  )
end

reviewer_sandbox = run.sandbox.scope(:reviewer)
```

When policy depends on files that the Workspace creates in `open`, Bubblewrap's `setup:` callback runs after the Workspace is ready and returns `policy:` plus optional `profiles:`. Layout remains declarative: `runtime_roots:` (only `/usr` by default), `tmpfs:`, read-only `masks:`, `proc:`, `uid:`, `gid:`, and a trusted `command_wrapper:` customize the namespace without overriding command assembly. Add `/etc` or `/opt` only when the child runtime needs them and those trees contain no application secrets. `limits:` configures bounded `read_bytes`, `write_bytes`, `list_entries`, and per-stream `output_bytes`; explicit calls may choose a smaller process-output limit. `exec_program` provides the same validated policy path for an interactive process handoff.

Selecting `:bubblewrap` on macOS, selecting a backend whose executable is missing, or selecting Docker without a reachable daemon or image raises a typed dependency or platform error. `LittleGhost::Sandbox.probe(:bubblewrap)` and `.probe(:docker)` let setup checks report availability without starting a Run.

### Treat networking as part of the Sandbox

An isolated Sandbox defaults to `network: :none`. Set `network: :inherit` only when the container or namespace may use ordinary outbound networking. An exact destination allowlist uses a run-scoped gateway:

```ruby
config.sandbox = {
  provider: :docker,
  image: "my-agent-runtime@sha256:...",
  network: {
    mode: :allowlist,
    allow: ["api.example.com:443"]
  }
}
```

The built-in Envoy gateway accepts exact lowercase DNS names and ports, rejects private and reserved resolved addresses, and puts Docker clients on an internal network whose only egress participant is the gateway. Proxy environment variables alone are advisory; `:unrestricted` therefore rejects `:none` and `:allowlist` instead of claiming enforcement. Envoy is optional: LittleGhost uses a pinned image with Docker or an application-installed native binary, and raises clearly when the selected runtime is unavailable. `gateway_options` can customize the executable, pinned image, pull behavior, or DNS resolvers.

An application that already owns an enforced proxy can select `gateway: {provider: :external, ...}` with explicit read-only mounts, child environment, proxy socket path, and a fail-closed `validate:` callback. `ExternalGateway` never starts or stops that proxy. Bubblewrap exposes its mounts, environment, and relay only to scopes that retain the allowlisted network; an offline profile receives none of them.

CONNECT allowlisting sees the destination and port but not encrypted methods, paths, headers, or bodies. Native Envoy gateways can opt into `inspection: :http` with a trusted headers-only `authorizer`; `forward_headers` explicitly selects extra request headers the callback may inspect, and `mutation_headers` selects the response headers it may set upstream. That mode creates a short-lived private CA, mounts only public trust artifacts into the child, keeps private keys outside it, streams bodies without sending them to the authorizer, and fails closed. The Docker Envoy runtime currently supports CONNECT allowlisting only and reports HTTP inspection as unsupported rather than weakening it.

The Run closes workspaces and sandboxes that LittleGhost creates for it after every outcome. That removes command containers, persistent containers, gateway processes and networks, sockets, and ephemeral trust material. If your application passes an existing instance instead, your application keeps ownership and must close it when its own lifecycle ends.

## Instrument without leaking the application

LittleGhost emits events as a request starts, calls a model or tool, moves between assembly steps, retries, and finishes. Instrumentation subscribers and OpenTelemetry exporters can send those events to your monitoring system.

An external telemetry service may receive application identifiers and event data. Redact sensitive values before they leave your boundary. Avoid attributes with many unique values, such as raw order or request IDs. Replacing one identifier does not make the rest of the data anonymous.

A composite `RunResult` includes short step summaries and trajectory queries. Keep detailed provider errors and sensitive diagnostics in trusted monitoring channels, not in model or user responses.

## Keep ownership and failure visible

One top-level Run owns the workspace and sandbox that LittleGhost creates for it, plus application resources registered with `run.register`. It closes those resources after success, failure, a partial response, or cancellation. Existing workspace or sandbox instances passed by the application remain caller-owned.

Ordinary execution failures appear on the Run and its final event. Cleanup, event delivery, or instrumentation can still raise an exception: once those boundaries fail, LittleGhost cannot promise a clean ending.

## Advanced: work with Runtime directly

A Runtime is the internal home for shared model resolution, loading, persistence, hooks, and resource factories. Most applications never need to handle it: `LittleGhost.configure` and class-level `.ask` are enough.

Use `LittleGhost.runtime` when an extension needs the shared object itself. Construct a separate Runtime only when one process deliberately hosts an isolated LittleGhost setup:

```ruby
configuration = LittleGhost::Configuration.new(root: isolated_root)
runtime = LittleGhost::Runtime.new(configuration: configuration)
agent = CustomerSupportAgent.new(runtime: runtime)
```

An explicit Runtime is an independent configuration snapshot. It does not replace LittleGhost's shared default.

One Runtime can serve independent calls from several threads. Each call gets its own Run, participants, Tools, and Runtime-created workspace and sandbox. An Agent or Assembly already bound to an active Run must stay with that Run.

Within one SessionStore instance, LittleGhost serializes calls sharing a Session. Multi-process deployments need coordination from their store. Custom stores, identity and credential resolvers, model resolvers, hooks, instrumentation subscribers, providers, and resource factories may receive concurrent calls and must be thread-safe.

Runtime has no shutdown step. Shared services supplied by the application keep their own lifecycle. Shut those services down with the rest of your application. If you installed process-wide instrumentation subscribers, flush or shut down `LittleGhost::Instrumentation` during application shutdown.

For exact constructors, options, events, extension contracts, and error behavior, continue into the API reference for `LittleGhost::Configuration`, `LittleGhost::Runtime`, `LittleGhost::Run`, `LittleGhost::Execution`, `LittleGhost::Session`, `LittleGhost::Tool`, and `LittleGhost::StreamEvent`.
