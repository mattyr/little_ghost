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

## Reuse a Runtime for shared services

Class-level `.ask` creates everything needed for one standalone call. A **Runtime** lets several calls reuse configuration and shared services.

```ruby
runtime = LittleGhost::Runtime.new(configuration: LittleGhost.configuration)
agent = CustomerSupportAgent.new(runtime: runtime)

first = agent.ask("Where is order 481?")
second = agent.ask("Can I change the address on order 481?")
```

The Runtime is reused here, not conversation history. Each `.ask` still creates
a new top-level Run. Add a stable session identity when one request should
continue an earlier conversation.

Build the Runtime after configuration is ready. Once created, it keeps that configuration snapshot.

A constructed Runtime can serve independent calls from several threads. Each call gets a new Run and new bound participants and Tools. By default, the Runtime also creates a workspace and sandbox for that call. The same standalone Agent entrypoint can start independent calls concurrently. An Agent or Assembly built for one active Run must stay with that Run.

Within one SessionStore instance, LittleGhost serializes calls that share a session. A multi-process deployment needs external coordination supported by its store.

Objects you give the Runtime may still receive calls from several threads. Make custom session stores, identity and credential resolvers, model resolvers, hooks, instrumentation subscribers, providers, and resource factories thread-safe. The workspace and sandbox instances created for one Run still belong only to that Run.

### Put the Runtime in a Rails application

Build the shared Runtime once, after application configuration loads:

```ruby
# config/initializers/little_ghost.rb
Rails.application.config.x.little_ghost.runtime =
  LittleGhost::Runtime.new(configuration: LittleGhost.configuration)
```

Use it for a fresh top-level call in a controller or job:

```ruby
class SupportQuestionsController < ApplicationController
  def create
    runtime = Rails.application.config.x.little_ghost.runtime
    agent = CustomerSupportAgent.new(runtime: runtime)
    run = agent.ask(
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

The controller supplies identity and account access from authenticated application state. The model cannot replace those values through its prompt or tool arguments. Pass a stable `session_id` only when a later request should continue this conversation. A background job can use the same Runtime and calling pattern.

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

Use `start_execution` when the caller must stay free for other work, or when you want to interrupt an active response:

```ruby
execution = agent.start_execution(message: question) do |event|
  event_buffer << event
end

execution.interrupt_response(message: "Include the latest ledger entry")
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

A Workspace gives one Run a place for files. A Sandbox decides how filesystem and process operations happen there.

`LittleGhost::UnrestrictedSandbox` uses the host machine with the Ruby process's permissions. It does not contain untrusted code. Expose only the tools the model needs, and use a real isolation boundary when untrusted code must run.

The Run closes workspaces and sandboxes created for it by the Runtime. If your application passes an existing instance instead, your application keeps ownership and must close it when its own lifecycle ends.

## Instrument without leaking the application

LittleGhost emits events as a request starts, calls a model or tool, moves between assembly steps, retries, and finishes. Runtime hooks can prepare trusted request data. Instrumentation subscribers and OpenTelemetry exporters can send those events to your monitoring system.

An external telemetry service may receive application identifiers and event data. Redact sensitive values before they leave your boundary. Avoid attributes with many unique values, such as raw order or request IDs. Replacing one identifier does not make the rest of the data anonymous.

A composite `RunResult` includes short step summaries and trajectory queries. Keep detailed provider errors and sensitive diagnostics in trusted monitoring channels, not in model or user responses.

## Keep ownership and failure visible

One top-level Run owns the workspace and sandbox created for it by the Runtime, plus application resources registered with `run.register`. It closes those resources after success, failure, a partial response, or cancellation. Existing workspace or sandbox instances passed by the application remain caller-owned.

Runtime itself has no shutdown step. Shared services supplied by the application keep their own lifecycle. Shut those services down with the rest of your application. If you installed process-wide instrumentation subscribers, flush or shut down `LittleGhost::Instrumentation` during application shutdown.

Ordinary execution failures appear on the Run and its final event. Cleanup, event delivery, or instrumentation can still raise an exception: once those boundaries fail, LittleGhost cannot promise a clean ending.

For exact constructors, options, events, extension contracts, and error behavior, continue into the API reference for `LittleGhost::Configuration`, `LittleGhost::Runtime`, `LittleGhost::Run`, `LittleGhost::Execution`, `LittleGhost::Session`, `LittleGhost::Tool`, and `LittleGhost::StreamEvent`.
