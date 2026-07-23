# LittleGhost

LittleGhost was extracted from an experimental self-improving AI-framework called Algernon.  While functional, it is still in an early stage so the API and functionality are not stable.

LittleGhost is a dependency-light agent framework for Ruby. It provides a conventional application layout, a streaming tool-calling loop, model providers, sessions, subagents, ERB prompts, and instrumentation.

LittleGhost requires Ruby 3.3 or newer and is licensed under the MIT License.

## Installation

```ruby
gem "little_ghost"
```

Provider SDKs and OpenTelemetry exporters are optional application dependencies. LittleGhost includes the OpenTelemetry API and native agent tracing; applications choose the SDK, processors, and exporters. The core uses Ruby standard libraries where practical.

## An application

LittleGhost applications follow a small conventional layout:

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
│   ├── application.rb
│   └── environment.rb
└── config.ru
```

`SupportApplication` resolves `SupportAgent` automatically. `SupportAgent` resolves `app/prompts/support/system.erb` automatically.
For a namespaced application, `Support::Application` resolves `Support::Agent` and `app/prompts/support/system.erb`.

```ruby
# config/application.rb
require "little_ghost"

class SupportApplication < LittleGhost::Application
  models SupportModels
end
```

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

Application classes configure shared framework services. Agent classes own agent behavior: model role, prompts, tools, limits, and delegation.

### Agent capabilities

`LittleGhost::Agent` includes its built-in capability mixins, but each capability remains inactive until its DSL is called. This keeps normal agents concise while keeping the implementation composable:

```ruby
class ApplicationAgent < LittleGhost::Agent
  detect_tool_loops
end

class SupportAgent < ApplicationAgent
  tools LittleGhost::Tools::WriteTodos
  offload_large_tool_results
  manage_context
end
```

The public mixins are `Agent::Skills`, `Agent::ToolLoop`, `Agent::ToolResultOffloading`, `Agent::ContextManagement`, and `Agent::Delegation`. They can also be included directly when building a custom base. `offload_large_tool_results` gives the model a bounded retrieval tool with pattern and line-range selection; `manage_context` summarizes older history as the model's context window fills. Todos are a normal tool, enabled with `tools LittleGhost::Tools::WriteTodos`. Tool-loop exclusions accept tool classes, instances, or names:

```ruby
detect_tool_loops except: AccountTool
```

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

LittleGhost generates missing run, invocation, and session identifiers. Actor identity remains an explicit caller value. Transport identifiers, callback details, and other application data stay in the invocation hash without becoming framework configuration. `Application.call` returns the completed `Run`; `Application.stream` yields generic `StreamEvent` objects and returns the run when enumeration finishes.

```ruby
run = SupportApplication.call(message: "Help")
puts run.response

SupportApplication.stream(message: "Help").each do |event|
  puts event.type
end
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

`require "little_ghost/tools"` adds dependency-free workspace and shell building blocks as `LittleGhost::Tools::Workspace` and `LittleGhost::Tools::Shell`. They are explicit application tools, not an implicit sandbox or delegation policy. `Workspace` provides best-effort Ruby path containment; applications that execute untrusted work should supply their own process or container isolation.

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

An agent can be exposed as a normal tool with `agent_as_tool`. A `subagent` declaration uses the bounded, concurrent subagent manager and adds spawn, message, wait, and listing tools. Each agent declares its own tools, so access policy remains visible on the class that receives it. Child capabilities are declared on the child agent itself.

Applications that discover agents at runtime can use `subagents { |run| definitions }`, returning `LittleGhost::Subagents::Definition` objects. Static `subagent` declarations take precedence over discovered definitions with the same kind, and all definitions share one manager and one control-tool surface.

## Prompts and components

Prompts are ERB. Templates can render partials with `partial "shared/rules"`. Application prompts override component prompts.

Reusable agents, tools, prompts, and skills can be packaged as a component:

```ruby
class SupportApplication < LittleGhost::Application
  component LittleGhost::Component.new(root: File.expand_path("../shared_agents", __dir__))
end
```

LittleGhost validates component ownership and rejects conflicting constants or prompt paths that escape their trusted roots.

## Sessions

Sessions work without application code. The fixed default is an in-memory store; environment variables never change it. AgentCore Memory is an explicit application choice:

```ruby
require "little_ghost/session_stores/agent_core_memory"

SupportApplication.session_store do
  LittleGhost::SessionStores::AgentCoreMemory.new(
    memory_id: ENV.fetch("SUPPORT_AGENTCORE_MEMORY_ID"),
    region: ENV.fetch("AWS_REGION")
  )
end
```

Applications can pass any `LittleGhost::SessionStore` to `session_store`, or use a block to create one when the application boots. Session history and state are loaded before the agent runs and checkpointed as coherent conversation turns complete, including before partial, canceled, or failed runs return. Private model reasoning is retained only while a run needs it for model continuation and is removed from session checkpoints. Stores implement explicit append and replacement operations, receive actor identity explicitly, and surface persistence failures.

`AgentCoreMemory` requires one active writer for each actor/session pair. It serializes writers inside one Ruby process, but AgentCore's immutable event API does not provide compare-and-swap across processes. Horizontally scaled applications must enforce that invariant with an external lock or a unique active-run record. If the invariant is violated, LittleGhost resolves the immutable fork deterministically when reading, so one concurrent commit is not retained.

## AG-UI

Internal events remain interface-neutral. After `require "little_ghost/ag_ui"`, `LittleGhost::AGUI::Adapter` is the translation boundary for AG-UI message, reasoning, tool, usage, trace, subagent, and run events. Provider-supplied plaintext reasoning is translated into AG-UI reasoning lifecycle events; applications decide which interfaces may present it. Encrypted reasoning and provider continuity artifacts remain private to the provider integration.

## Instrumentation and tracing

LittleGhost automatically creates hierarchical OpenTelemetry spans for agents, agent turns, model calls, tools, and subagents. The application run and its primary agent share one root agent span; delegated agents remain distinct children. Spans use flat, dot-separated OpenTelemetry GenAI attributes for operations, agents, models, providers, tool definitions, response metadata, timing, and token usage. Prompt, response, message, tool-argument, and exception content is excluded by default. Applications can opt into bounded, scrubbed content capture with `LittleGhost::Support::ContentCapture`. With no tracer provider configured, OpenTelemetry's no-op provider keeps the same application code dependency-free at runtime; an application can register any OpenTelemetry SDK provider and exporter.

Instrumentation is the code that records signals; telemetry is the emitted data; tracing is the span-based signal LittleGhost provides out of the box. `LittleGhost::Support::Instrumentation` supplies the generic instrumentation hooks and emits correlated lifecycle events, model retries, and tool-loop decisions. `LittleGhost::Tracing::OpenTelemetry` turns those events into spans. Environment variables never install an exporter:

```ruby
class MetricsSubscriber
  def self.install(instrumentation:, **)
    instrumentation.subscribe(new)
  end

  def call(name, attributes)
    Metrics.record(name, attributes)
  end
end

SupportApplication.instrument MetricsSubscriber
```

`instrument` installs each declared instrumentation setup object and supplies the application's instrumentation plus a conventional service name. This is the natural place to register an OpenTelemetry tracer provider or add custom subscribers. Subscribers receive the event name and its complete structured attributes. Instrumentation failures are isolated from the agent run. The instrumentation object delegates flush, shutdown, and trace-context behavior to subscribers that provide those capabilities.

Generic framework utilities live under `LittleGhost::Support`: callbacks, loading, instrumentation, cancellation, and bounded execution. They are public building blocks, while agent-specific behavior stays under `LittleGhost::Agent` and can be composed through its mixins.

## Direct agents

Applications are optional for small or embedded uses:

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
