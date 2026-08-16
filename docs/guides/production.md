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

For a trusted operational interface that needs intermediate and nested Agent work, pass `include_agent_events: true` and filter for `:agent_stream`. Enable the option only from trusted application code, never from unchecked request or model input. Those events include complete routed inputs, reasoning, tool arguments and results, model output, errors, and final results. They are untrusted and may be sensitive. Redact them before logging or transport, and authorize the destination for every participant and provider involved. LittleGhost's AG-UI adapter intentionally ignores these contextual wrappers unless the application translates them itself.

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

A **Workspace** names the host paths associated with a Run. A **Sandbox** governs bounded filesystem operations and child processes that deliberately pass through it. A custom Ruby Tool remains trusted application code unless it delegates work to the bound Sandbox.

The dependency-free default is an application-root Workspace with `LittleGhost::Sandboxes::Unrestricted`. It is not process or network isolation. Select an enforcing backend explicitly when a model can influence commands; LittleGhost raises when that backend is unavailable instead of silently falling back:

```ruby
require "fileutils"
require "tmpdir"

LittleGhost.configure do |config|
  config.workspace = lambda do |**|
    root = Dir.mktmpdir("little-ghost-support-")
    LittleGhost::Workspace.new(
      root:,
      teardown: lambda do |workspace:, **|
        FileUtils.remove_entry_secure(workspace.root) if File.exist?(workspace.root)
      end
    )
  end
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

The temporary Workspace above is useful when files should live for one Run. Use application-managed storage, with tenant isolation and concurrency control, when files must persist or several Runs share a root.

The Run opens a Runtime-created Workspace before its Sandbox and closes them in reverse order after every outcome. Closing a Workspace invokes its configured teardown; it does not delete files by default. Cleanup failures raise because LittleGhost cannot confirm a clean shutdown of every owned resource. Existing instances passed by the application remain caller-owned.

[Workspaces, Sandboxes, and Tools](sandboxing.md) explains backend selection, named Workspace paths, lifecycle callbacks, mounts, Scopes, profiles, process persistence, filtered networking, hosting boundaries, and deployment validation in depth.

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
