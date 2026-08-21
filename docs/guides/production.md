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

Prompts, caller input and history, Tool results, and attachments may go to the
selected provider. Choose configured providers that are appropriate for that
data and its retention or residency needs.

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

## Use an existing Fiber scheduler

If your application already runs inside a Ruby Fiber scheduler, LittleGhost
uses that scheduler for work that can overlap: parallel Tool calls, Workflow
and Graph branches, subagent turns, background Executions, and nested code-mode
Tool calls. LittleGhost does not install or run a scheduler. Work started
outside a scheduled fiber uses worker threads instead.

For example, an application using the optional `async` gem can let several
requests make progress on one thread while each request waits for network I/O.
Add `gem "async"` to the application's bundle, then start the calls inside an
Async task:

```ruby
require "async"

questions = [
  "How long do refunds take?",
  "Can I update my delivery address?"
]

answers = Async do |task|
  questions.map do |question|
    task.async { CustomerSupportAgent.ask(question).response }
  end.map(&:wait)
end.wait
```

The default `:auto` backend selects fibers only when work begins inside a fiber
managed by the active scheduler. Otherwise, it selects threads. Force threads
when your Tools or extensions call libraries that block the current thread:

```ruby
LittleGhost.configure do |config|
  config.concurrency_backend = :thread
end
```

Set the backend to `:fiber` when starting work outside a scheduled fiber should
be an application error. LittleGhost then raises
`LittleGhost::ConfigurationError` instead of falling back to a thread.

Fiber scheduling helps while work waits for I/O; it does not make CPU-heavy
Ruby code run in parallel. Ordinary IO, including local file reads and writes,
stays on the scheduled fiber and uses Ruby's scheduler hooks. Configuration,
loading, and extension construction run in the calling context. A slow
filesystem or blocking library in any of those paths can pause the other
fibers on that thread.

A few boundaries remain threaded because their cleanup or durability contract
requires it. Blocking provider or subprocess adapters may own dedicated
threads that can be interrupted or kept draining during cleanup. Run-scoped
certificate generation and process startup share a small, lazily created
blocking pool. The Filesystem SessionStore uses a separate bounded pool for
durable transactions; it releases a session lock instead of holding it while
waiting for worker capacity.
Fiber mode removes orchestration threads; it does not promise a thread-free
Run.

Custom Tools, providers, SessionStores, hooks, and callbacks can be entered by
several threads or by fibers interleaved on one thread. Protect shared mutable
state, keep lock scope narrow, and do not call application callbacks while
holding a lock. Use your scheduler library's blocking-operation facility for a
call that does not cooperate with Ruby's Fiber scheduler. If the extension
cannot do that, select the `:thread` backend for its Runtime.

Pass request-specific values through the Invocation context or another explicit
argument. Do not use `thread_variable_set` for request state because every
fiber on the thread shares those values. `Thread.current[:key]` is fiber-local,
but LittleGhost does not copy application-defined entries into each worker
task.

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

`.stream_ask` runs on the caller's fiber or thread and yields `StreamEvent`
values as the answer arrives:

```ruby
stream = CustomerSupportAgent.stream_ask(question)

run = stream.each do |event|
  publish(event) if event.type == :text_delta
end

record_outcome(run.outcome, error_type: run.error&.class&.name)
```

Composite assembly streams include intermediate and nested Agent work as `:agent_stream` events. This default also applies to the event consumer passed to `start_execution`. Pass `include_agent_events: false` when only the ordinary public stream is needed.

> **Safety note:** Contextual events can include inputs, reasoning, Tool
> arguments and results, errors, and output from every participant. Check that
> the destination may see the complete Run, or filter the events before sending
> or storing them. LittleGhost's AG-UI adapter ignores these events unless the
> application translates them explicitly.

Use `start_execution` when the caller must stay free for other work, or when you want to deliver an interjection to an active response:

```ruby
execution = agent.start_execution(message: question) do |event|
  event_buffer << event
end

execution.interject(message: "Include the latest ledger entry")
execution.wait(deadline: Time.now + 30)
execution.run.completed?
```

The event block runs on the Execution's background task. With `:auto`, that is
a scheduled fiber when `start_execution` is called from a scheduled fiber, and
a worker thread otherwise. Keep the block quick because it applies backpressure
to the Run's event stream. Cancellation, deadlines, and `close` ask the work to
stop; they cannot forcibly end arbitrary provider or Tool code or undo actions
that already happened. Keep the application's scheduler running until a
scheduler-backed Execution finishes or closes.

## Keep Tool permission checks in application code

A Tool schema checks the shape of model-supplied input. Your application still
owns permission checks, safe retries, rate limits, and auditing. An ordinary
Tool runs in the Ruby process; a Sandbox contains only file or child-process
work that deliberately passes through it.

Use the Tool binding's `run` to read current, application-established values
from `run.invocation.context`. Don't rely on model arguments for identity or
account membership.

Treat `RunContext#state` as mutable working and Session state. Revalidate anything restored from an earlier request. Synchronize access when parallel Tools share mutable state, or mark every Tool that reads or changes it as `exclusive true`.

A `ToolError` message is visible to the model, so keep it safe to share. LittleGhost hides unexpected exception messages from model-facing results.

When a step retries, its tool calls may happen again too. Prefer read-only work, idempotency keys, or operations that are safe to repeat.

[Tools](tools.md) develops this pattern from the first application Tool through
bindings, concurrency, sandbox delegation, and code mode.

## Choose workspace and sandbox behavior explicitly

A **Workspace** names the host paths associated with a Run. A **Sandbox**
controls filesystem operations and child processes deliberately sent through
it. A custom Ruby Tool stays in the application process unless it delegates
work to the bound Sandbox.

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
    provider: :native,
    files: {root: :read_write},
    root_filesystem: :isolated,
    environment: {inherit: false, set: {"LANG" => "C.UTF-8"}},
    network: :none
  }
end
```

The temporary Workspace above is useful when files should live for one Run. Use application-managed storage, with tenant isolation and concurrency control, when files must persist or several Runs share a root.

The Run opens a Runtime-created Workspace before its Sandbox and closes them in reverse order after every outcome. Closing a Workspace invokes its configured teardown; it does not delete files by default. Cleanup failures raise because LittleGhost cannot confirm a clean shutdown of every owned resource. Existing instances passed by the application remain caller-owned.

[Workspaces and Sandboxes](sandboxing.md) explains backend selection, logical
Workspace paths, files, process-only runtime paths, Scopes, filtered
networking, and deployment validation in depth.

[Code Mode](code_mode.md) applies that setup to model-authored Ruby or
optional JavaScript that composes the Agent's existing Tools.

## Protect data in telemetry

LittleGhost emits events as a request starts, calls a model or tool, moves between assembly steps, retries, and finishes. Instrumentation subscribers and OpenTelemetry exporters can send those events to your monitoring system.

An external telemetry service may receive application identifiers and event
data. Redact sensitive values before exporting them. Avoid attributes with many
unique values, such as raw order or request IDs.

A composite `RunResult` includes short step summaries and trajectory queries.
Keep detailed provider errors and sensitive diagnostics in your monitoring
system, not in model or user responses.

## Know what the Run closes and raises

One top-level Run owns the workspace and sandbox that LittleGhost creates for it, plus application resources registered with `run.register`. It closes those resources after success, failure, a partial response, or cancellation. Existing workspace or sandbox instances passed by the application remain caller-owned.

Ordinary execution failures appear on the Run and its final event. Cleanup,
event delivery, or instrumentation can still raise an exception when
LittleGhost cannot promise a clean ending.

## Advanced: work with Runtime directly

A Runtime is the internal home for shared model resolution, loading, persistence, hooks, and resource factories. Most applications never need to handle it: `LittleGhost.configure` and class-level `.ask` are enough.

Use `LittleGhost.runtime` when an extension needs the shared object itself. Construct a separate Runtime only when one process deliberately hosts an isolated LittleGhost setup:

```ruby
configuration = LittleGhost::Configuration.new(root: isolated_root)
runtime = LittleGhost::Runtime.new(configuration: configuration)
agent = CustomerSupportAgent.new(runtime: runtime)
```

An explicit Runtime has its own independent configuration. It does not replace
LittleGhost's shared default.

One Runtime can serve independent calls from several threads and fibers. Each
call gets its own Run, participants, Tools, and Runtime-created Workspace and
Sandbox. An Agent or Assembly already bound to an active Run must stay with
that Run.

Within one SessionStore instance, LittleGhost serializes calls sharing a
Session. Multi-process deployments need coordination from their store. Custom
stores and other shared extension objects may receive concurrent calls. A
scheduler-aware I/O wait can let another fiber enter the same object on the
same thread, so protect shared mutable state without relying on thread identity.

Runtime has no shutdown step. Shared services supplied by the application keep their own lifecycle. Shut those services down with the rest of your application. If you installed process-wide instrumentation subscribers, flush or shut down `LittleGhost::Instrumentation` during application shutdown.

For exact constructors, options, events, extension contracts, and error behavior, continue into the API reference for `LittleGhost::Configuration`, `LittleGhost::Runtime`, `LittleGhost::Run`, `LittleGhost::Execution`, `LittleGhost::Session`, `LittleGhost::Tool`, and `LittleGhost::StreamEvent`.
