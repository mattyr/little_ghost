# LittleGhost

LittleGhost was extracted from an experimental self-improving AI-framework called Algernon.  While functional, it is still in an early stage so the API is not stable.

LittleGhost is a dependency-light agent framework for Ruby. It provides a conventional agent layout, a streaming tool-calling loop, model providers, sessions, subagents, ERB prompts, and instrumentation.

LittleGhost requires Ruby 3.3 or newer and is licensed under the MIT License.

## Installation

```ruby
gem "little_ghost"
```

Provider SDKs and OpenTelemetry exporters are optional application dependencies. LittleGhost includes the OpenTelemetry API and native agent tracing; applications choose the SDK, processors, and exporters. The core uses Ruby standard libraries where practical.

## An agent

LittleGhost agents follow a small conventional layout:

```text
my_agent/
├── app/
│   ├── agents/
│   │   ├── support_agent.rb
│   │   └── research_agent.rb
│   ├── prompts/
│   │   ├── support/system.erb
│   │   └── research/system.erb
│   ├── skills/
│   └── tools/
├── config/
│   └── little_ghost.rb
└── config.ru
```

`SupportAgent` resolves `app/prompts/support/system.erb` automatically. For a namespaced agent, `Support::Agent` resolves the matching prompt path.

```ruby
# config/little_ghost.rb
require "little_ghost"

LittleGhost.configure do |config|
  config.models SupportModels
  config.workspace { |runtime:| LittleGhost::Workspace.new(root: runtime.root) }
  config.sandbox do |workspace:, runtime:|
    LittleGhost::UnrestrictedSandbox.new(workspace:, writable: true)
  end
end
```

LittleGhost does not load the configuration file when the gem is required. The first `SupportAgent` runtime access resolves the configured root, requires `config/little_ghost.rb` if it exists, and materializes the resulting settings into the runtime used by the agent. Configuration changes must therefore be made before that first runtime access.

```ruby
# app/agents/support_agent.rb
class SupportAgent < LittleGhost::Agent
  description "Handles support requests"
  model "support"
  limits max_turns: 40

  tools LittleGhost::Tools::WriteTodos
  detect_tool_loops
  skills paths: [File.expand_path("../skills", __dir__)]

  tools AccountTool
  tools { run.invocation[:admin] ? [AdminTool] : [] }

  subagent ResearchAgent, kind: "research"
end
```

The configuration object owns shared framework services. Agent classes own agent behavior: model role, prompts, tools, limits, and delegation. The configured agent is the primary entrypoint. It can be invoked through class methods, or instantiated for a console-friendly interface: `SupportAgent.new.ask("Help")` and `SupportAgent.new.stream_ask("Help")`.

### Agent capabilities

`LittleGhost::Agent` includes its built-in capability mixins, but each capability remains inactive until its DSL is called. This keeps normal agents concise while keeping the implementation composable:

```ruby
class ApplicationAgent < LittleGhost::Agent
  detect_tool_loops
end

class SupportAgent < ApplicationAgent
  tools LittleGhost::Tools::WriteTodos
  manage_context
end
```

The public mixins are `Agent::Skills`, `Agent::ToolLoop`, `Agent::ContextManagement`, and `Agent::Delegation`. They can also be included directly when building a custom base. `manage_context` summarizes older history as the model's context window fills. Todos are a normal tool, enabled with `tools LittleGhost::Tools::WriteTodos`. Tool-loop exclusions accept tool classes, instances, or names:

```ruby
detect_tool_loops except: AccountTool
```

Tool results are universally limited to approximately 10,000 tokens before they enter model context, session history, streams, or diagnostics. LittleGhost estimates one token per four UTF-8 bytes and preserves the beginning and end of oversized results. Set a different per-agent budget with `limits max_tool_result_tokens: 5_000`. Removed middle content is not retained.

Agent callbacks are an inheritable class-level DSL. Capability methods register only the callbacks they need when the capability is enabled; merely including a mixin has no runtime effect. `after_initialize` is available for per-agent state, while invocation, model, and tool callbacks handle runtime behavior. Tools remain class-level declarations; zero-argument tool blocks run against the agent instance and can use `run` directly. Custom agent behavior uses the same interface:

```ruby
class AuditedAgent < LittleGhost::Agent
  tools { run.available_tools }
  after_initialize { @audit = Audit.for(run) }
  before_model :record_request
  after_tool do |payload|
    Audit.record(payload.fetch(:tool_use).name)
  end

  private

  def record_request(payload)
    Audit.record(payload.fetch(:request).model)
  end
end
```

## Invocations and runs

An `Invocation` is an open request environment with indifferent string and symbol keys. It defines common agent fields while retaining any application-specific values:

```ruby
invocation = LittleGhost::Invocation.new(
  message: "Help with my transfer",
  account_id: "account-1",
  model_profiles: {"support" => {"model_id" => "openai/gpt-5"}}
)

invocation.message
invocation[:account_id]
```

LittleGhost generates missing run, invocation, and session identifiers. Actor identity remains an explicit caller value. Transport identifiers, callback details, and other application data stay in the invocation hash without becoming framework configuration. Agent instances are the invocation boundary: `SupportAgent.new.ask(...)` returns the completed `Run`, while `SupportAgent.new.stream_ask(...)` yields generic `StreamEvent` objects and returns the run when enumeration finishes.

```ruby
agent = SupportAgent.new
run = agent.ask("Help")
puts run.response

agent.stream_ask("Help").each do |event|
  puts event.type
end

SupportAgent.new.ask("Help")
SupportAgent.new.stream_ask("Help").each { |event| puts event.type }
```

The run opens and closes its session, agents, subagent managers, and other registered resources. Application-specific resources can be registered on the run for the same lifecycle management.

`Invocation` normalizes its current `message` and every entry in `history` into `LittleGhost::Message` objects before the run reaches an agent. Strings become user messages; hashes can describe structured content directly:

```ruby
LittleGhost::Invocation.new(
  message: {
    role: "user",
    content: [{type: "text", text: "Help with my transfer"}]
  },
  history: [{role: "assistant", content: "How can I help?"}]
)
```

Messages and content blocks serialize to JSON-safe hashes. Image and document bytes use strict base64 encoding and round-trip through `Message.coerce`. Transport adapters should convert their wire formats into this canonical invocation shape. When a stored session has history, it is authoritative; invocation history is the fallback for a new session.

## Models

Agents select a logical role. A model registry maps roles to providers and profiles, while invocation `model_profiles` can override either a registered parent or the exact requested role:

```ruby
class SupportModels < LittleGhost::ModelRegistry
  def initialize
    super
    provider(:openrouter) do |model:, **|
      LittleGhost::Providers::OpenRouter.new(
        api_key: ENV.fetch("OPENROUTER_API_KEY"),
        model:
      )
    end
    profile "support",
      provider: :openrouter,
      model: "openai/gpt-5",
      settings: {temperature: 0.2}
  end
end
```

Built-in clients cover OpenAI, OpenAI-compatible APIs, OpenRouter, and Amazon Bedrock. Every client emits the same normalized stream protocol.

Model profiles support dotted roles. Resolution tries the exact role and then successively shorter registered parents, so `engineering.subagent.review` can inherit from `engineering.subagent`. Invocation overrides layer from each registered inheritance parent through the original exact role.

## Tools and subagents

```ruby
class WeatherTool < LittleGhost::Tool
  tool_name "weather"
  description "Look up weather"
  input_schema(
    type: "object",
    properties: {city: {type: "string"}},
    required: ["city"],
    additionalProperties: false
  )

  def call(input, context:)
    "Sunny in #{input.fetch("city")} for #{run.invocation.actor_id}"
  end
end
```

Tools are instantiated once per agent run and receive that run through `LittleGhost::Tool#run`. Static tools are declared by class; an explicit resolver proc can select tools from invocation or run state. Related tool classes can be grouped with normal Ruby modules or classes. Duplicate model-visible names are configuration errors. Per-run tools that implement `close` are closed automatically, including tools owned by delegated agents. A mutating tool can declare `exclusive true`; each call to an exclusive tool acquires a lock shared by every agent in the run, while other calls in the batch execute outside that lock.

`Workspace` identifies the root directory and participates in the agent resource lifecycle. `Sandbox` is the common interface for filesystem and process execution. The default `UnrestrictedSandbox` uses only Ruby standard-library facilities: its filesystem operations provide best-effort workspace containment, but cannot defend against concurrent adversarial filesystem mutation, and its commands execute directly on the host with the Ruby process's permissions. It is not a security boundary. Applications that execute untrusted work should configure an isolated implementation:

```ruby
LittleGhost.configure do |config|
  config.workspace { |runtime:| ProjectWorkspace.new(root: runtime.root) }
  config.sandbox { |workspace:, runtime:| ContainerSandbox.new(workspace:) }
end
```

Configuration stores these builders as settings; Runtime invokes them for an entering agent. A run opens Workspace before Sandbox and closes owned resources in reverse order. Standalone agent instances retain their resources across repeated `ask` calls and close Sandbox before Workspace.

`require "little_ghost/tools"` adds dependency-free adapters as `LittleGhost::Tools::Filesystem` and `LittleGhost::Tools::Shell`. Both receive `sandbox:` and expose only model-facing schemas and formatting; the configured sandbox remains responsible for enforcing every filesystem and execution operation.

For embedded or runtime-generated tools, `Tool.define` remains available:

```ruby
weather = LittleGhost::Tool.define(
  name: "weather_now",
  description: "Look up current weather",
  input_schema: {
    type: "object",
    properties: {city: {type: "string"}},
    required: ["city"],
    additionalProperties: false
  }
) { |input| "Sunny in #{input.fetch("city")}" }
```

An agent can be exposed as a normal tool with `agent_as_tool`. A `subagent` declaration uses the bounded, concurrent subagent manager and adds spawn, queued-message, interrupt, wait, and listing tools. Each agent declares its own tools, so access policy remains visible on the class that receives it. Child capabilities are declared on the child agent itself.

`Agent#interrupt` synchronously adds a message to the next model request of one active invocation and returns only the ordinary text from that model response. `Agent#interrupt_response` additionally reports whether that response initiated tool calls. Tool calls from the same response stay inside the interrupted agent and continue its current run; delivery does not imply that the agent stopped. The subagent manager exposes the text, response disposition, and current lifecycle snapshot as `interrupt_subagent`; `send_message_to_subagent` remains the separate FIFO mechanism for a later turn after active work finishes.

Active subagent snapshots include one monotonic `progress.sequence`. It advances across direct and nested model/tool activity even when the latest bounded `progress.message` is unchanged or unavailable, so consumers can distinguish quiet activity from an unchanged narrative without a second counter.

`wait_for_subagents` distinguishes a settled result from historical context. An idle identity whose latest turn succeeded returns `response` and `response_turn`. If newer work is queued, running, persisting, failed, or cancelled, the latest successful result remains available as `previous_response` and `previous_response_turn` alongside the current status, progress, or error. A previous response is context only and never represents the result of the newer turn.

Subagent conversations are durable by default when the configuration has a `SessionStore`. The primary agent is `/root`; `spawn_subagent` accepts a model-chosen `task_name` and returns a stable canonical path such as `/root/check_provider_health` or `/root/investigate_customer/explore_source`. Names use lowercase letters, digits, and underscores, are limited to 40 characters, and must be unique among siblings; a collision returns an actionable error so the caller can choose a different name. The full path can be up to 1,024 characters. A custom subagent factory that returns a `LittleGhost::Agent` must build it with the supplied canonical ID as `agent_path`; the agent's runtime provides that binding. The persistence conversation ID remains a separate UUID. LittleGhost owns a derived registry session, a compact child transcript, and bounded two-slot committed-state snapshots; invocation context cannot replace the registry. Store-visible parent links are SHA-256 pseudonyms rather than raw parent session IDs. A later invocation can discover inactive conversations with `list_subagents` and pass the same canonical path to `send_message_to_subagent`; LittleGhost restores the child transparently. Listing is newest-first, supports kind filtering and bounded cursor pagination, retains at most the configured identity limit, and does not activate persisted children. `wait_for_subagents` and `interrupt_subagent` operate only on work active in the current invocation.

The durable transcript is intentionally compact. LittleGhost persists delegated tasks and follow-ups, successful interrupt message/ordinary-text response pairs, and each successful turn's final returned response; structured values use their serialized JSON representation. Internal tool calls, reasoning, progress updates, and other execution details remain inside the live child. A child transcript and state snapshot become visible only when the framework registry advances their committed message-count boundary. Failed registry writes can leave unreachable storage, but restoration never exposes it and repairs an orphaned child suffix back to the last committed boundary. Failed or cancelled turns therefore do not expose a partial exchange. A child can declare subagents of its own; their registries and derived sessions follow the same rules, so nested conversations also resume across invocations.

Durability is an application declaration, not a model-controlled spawn option. Use `persist: false` only for a child that must remain invocation-local:

```ruby
class CoordinatorAgent < LittleGhost::Agent
  subagent ScratchAgent, kind: "scratch", persist: false
end
```

Applications that discover agents at runtime can use `subagents { |run| definitions }`, returning `LittleGhost::Subagents::Definition` objects. Static `subagent` declarations take precedence over discovered definitions with the same kind, and all definitions share one manager and one control-tool surface.

Agents that must return machine-readable data can declare a JSON-schema result contract:

```ruby
class InvestigationAgent < LittleGhost::Agent
  result_schema(
    {
      type: "object",
      properties: {
        claims: {type: "array", items: {type: "string"}},
        confidence: {type: "string", enum: %w[high medium low]}
      },
      required: %w[claims confidence],
      additionalProperties: false
    },
    name: "investigation_result"
  )
end
```

LittleGhost selects the result mechanism from the resolved model's capabilities. Provider-native structured output is preferred when available; otherwise LittleGhost supplies the schema as a strict terminal tool when the model supports both tools and forced tool choice. Applications still receive the same locally validated value through `RunResult#structured_result` and do not need to branch on the selected mechanism. Automatic selection fails closed when model capabilities are unknown instead of sending an assumed provider request. Pass `strategy: :provider` or `strategy: :tool` to `result_schema` only when an explicit override is required.

A missing or invalid result receives one repair turn before `StructuredResultError` is raised. The terminal result tool must be the only tool call in its response; mixed calls are rejected without executing ordinary tools. Result schemas use a portable strict subset of the tool-schema keywords: every object must set `additionalProperties: false` and require every declared property; represent optional values with nullable types. Unsupported JSON Schema keywords and invalid provider schema names are rejected when the agent class is defined rather than silently ignored. Results also have framework-level serialized-size, nesting, and node-count limits, and retained conversation history contains only a redacted result marker.

Structured values remain structured when the agent is called directly, exposed as an agent tool, or managed as a subagent. Values are retained only in the dedicated structured-result channel; conversation history and telemetry contain a redacted marker. Result telemetry records the schema, validation status, duration, and usage without including the payload. Evidence-sensitive agents can declare `capture_diagnostics false` to keep all of their model and tool content out of diagnostic telemetry while preserving low-cardinality lifecycle and usage attributes.

Use `LittleGhost::Workflow` for a small functional composition. Every `invoke` inherits the current input, history, state, settings, cancellation, deadline, and trace parent. Read an intermediate agent's `output`, then return the final `invoke` so its response streams to the caller:

```ruby
class ResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    route = invoke(RouterAgent).output
    return invoke(MainAgent) unless route["research"]

    research = invoke(ResearchAgent).output
    invoke MainAgent, input: <<~PROMPT
      Original request:
      #{input.text}

      Research:
      #{research}
    PROMPT
  end
end
```

Declare a workflow as the configured entrypoint:

```ruby
LittleGhost.configure do |config|
  config.agent MainAgent
  config.entrypoint ResponseWorkflow
end
```

Agent entrypoints produce one fused root `invoke_agent` span. Workflow entrypoints instead produce an `invoke_workflow` root with `gen_ai.workflow.name`; every agent invoked by the workflow remains a distinct child `invoke_agent` span.

`RunResult#output` returns the validated structured value when the agent has a result schema and otherwise returns its text. Workflows use ordinary Ruby branching; use a graph runtime only when the application needs durable node state, joins, or cycles.

## Prompts and lookup paths

Prompts are ERB. Templates can render partials with `partial "shared/rules"`. Agent prompts override configured fallback prompts.

Prompt and skill lookup roots default to the application directories and can be extended or replaced in configuration:

```ruby
LittleGhost.configure do |config|
  config.prompt_paths << File.expand_path("../shared_agents/prompts", __dir__)
  config.skill_paths << File.expand_path("../shared_agents/skills", __dir__)
end
```

Use `config.prompt_paths = ["/little_ghost_app/prompts"]` or `config.skill_paths = ["/little_ghost_app/skills"]` to replace the conventional `app/` roots. Lookup paths are ordered: the first matching prompt wins, while later skill roots override duplicate skill names.

## Sessions

Sessions work without application code. The fixed default is an in-memory store; environment variables never change it. AgentCore Memory is an explicit application choice:

```ruby
require "little_ghost/session_stores/agent_core_memory"

LittleGhost.configure do |config|
  config.session_store = {
    provider: LittleGhost::SessionStores::AgentCoreMemory,
    memory_id: ENV.fetch("SUPPORT_AGENTCORE_MEMORY_ID"),
    region: ENV.fetch("AWS_REGION")
  }
end
```

The session-store definition names its provider class and constructor options; the runtime owns construction. Session history and state are loaded before the agent runs and checkpointed as coherent conversation turns complete, including before partial, canceled, or failed runs return. Private model reasoning is retained only while a run needs it for model continuation and is removed from session checkpoints. Stores implement explicit append and replacement operations, receive actor identity explicitly, and surface persistence failures.

`AgentCoreMemory` requires one active writer for each actor/session pair. It serializes writers inside one Ruby process, but AgentCore's immutable event API does not provide compare-and-swap across processes. Horizontally scaled applications must enforce that invariant with an external lock or a unique active-run record. If the invariant is violated, LittleGhost resolves the immutable fork deterministically when reading, so one concurrent commit is not retained.

## AG-UI

Internal events remain interface-neutral. After `require "little_ghost/ag_ui"`, `LittleGhost::AGUI::Adapter` is the translation boundary for AG-UI message, reasoning, tool, usage, trace, subagent, and run events. Provider-supplied plaintext reasoning is translated into AG-UI reasoning lifecycle events; applications decide which interfaces may present it. Encrypted reasoning and provider continuity artifacts remain private to the provider integration.

## Structured operational events

LittleGhost reports runtime facts through `LittleGhost::Events` instead of writing string messages through Ruby's `Logger` interface. Every event has a name, one of the `debug`, `info`, `warn`, or `error` levels, a structured payload, execution-scoped context, and a nanosecond timestamp. Framework and application code can emit or listen from anywhere without adding logger dependencies to object constructors:

```ruby
class EventCollector
  def emit(event)
    EventStore.write(event)
  end
end

LittleGhost::Events.subscribe(EventCollector.new) do |event|
  event[:level] == :warn || event[:level] == :error
end

LittleGhost::Events.with_context(request_id: "request-123") do
  LittleGhost::Events.info("support.case.opened", case_id: "case-456")
end
```

The default console listener writes newline-delimited JSON to standard error, keeping standard output available for application protocols and results. Sensitive keys and recognizable credential formats are redacted before console output. Applications can replace the process-wide reporter or add listeners for log aggregation, durable event streams, or alerts; custom listeners receive the original structured event and own their destination-specific filtering policy. Listener failures are isolated from the operation that emitted the event.

## Instrumentation and tracing

LittleGhost publishes hierarchical lifecycle instrumentation for agents, workflows, agent turns, model calls, tools, and subagents without selecting a tracing backend. Applications can subscribe `LittleGhost::Tracing::OpenTelemetry` to turn those notifications into spans. An agent entrypoint shares the application run's root agent span; a workflow entrypoint owns a separate workflow root and keeps every invoked agent as a distinct child. Spans use flat, dot-separated OpenTelemetry GenAI attributes for operations, agents, workflows, models, providers, tool definitions, response metadata, timing, and token usage. Prompt, response, message, tool-argument, and exception content is excluded by default. Applications can opt into scrubbed content capture with `LittleGhost::Support::ContentCapture`. Captured content is complete by default; applications can set `max_bytes` explicitly or apply backend-specific limits in their exporter.

Instrumentation records timed operations for telemetry backends; structured operational events communicate noteworthy runtime facts to listeners. `LittleGhost::Instrumentation` is a process-wide notification facade, similar to Active Support's instrumentation API. Framework and application code can publish or subscribe from anywhere without adding instrumentation to object constructors. `LittleGhost::Tracing::OpenTelemetry` turns lifecycle notifications into spans. Environment variables never install an exporter:

```ruby
class MetricsSubscriber
  def call(name, attributes)
    Metrics.record(name, attributes)
  end
end

LittleGhost.configure do |config|
  config.instrument LittleGhost::Tracing::OpenTelemetry.new
  config.instrument MetricsSubscriber.new
end
```

`instrument` accepts subscriber instances and adds them directly to the process-wide instrumentation bus. LittleGhost does not install a default subscriber; applications explicitly select OpenTelemetry, metrics, or any other backend they want. Applications configure an OpenTelemetry tracer provider or exporter before constructing the tracing subscriber. Subscribers receive the event name and its complete structured attributes, including the service name for runtime-owned work. Instrumentation is process-wide, so one process is one telemetry and content-capture trust boundary; applications that require separate exporters or data policies should run those services in separate processes. Instrumentation failures are isolated from the agent run. `LittleGhost::Instrumentation` delegates flush, shutdown, and trace-context behavior to subscribers that provide those capabilities.

Request-scoped configuration and telemetry correlation use `LittleGhost::ExecutionState`. State is isolated between both Puma-style request threads and Falcon-style request fibers, inherited by child fibers, and explicitly propagated into worker threads created by LittleGhost.

Generic framework utilities live under `LittleGhost::Support`: callbacks, loading, cancellation, and bounded execution. They are public building blocks, while instrumentation has its own framework-level facade and agent-specific behavior stays under `LittleGhost::Agent`.

## Direct agents

The configuration file is optional for small or embedded uses:

```ruby
agent = SupportAgent.new(model: model, tools: [weather])
puts agent.call("What is the weather in Buenos Aires?").text
```

## Development

```sh
bundle install
bundle exec rake test
bundle exec standardrb --no-fix
```
