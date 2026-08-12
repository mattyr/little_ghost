# Core Concepts

LittleGhost gives Ruby software two ways to compose AI behavior. Agents can choose among validated tools and delegated specialists, while agentic workflows keep required ordering and branching under application control. The customer support example makes that boundary visible: CustomerSupportModels chooses provider-backed models, CustomerSupportAgent owns behavior, HelpCenterLookupTool exposes a narrow help center lookup, ResearchAgent handles delegated investigation, and ResponseWorkflow imposes a deterministic sequence when the surrounding system requires one.

```text
shared configuration
└── CustomerSupportModels ── resolves logical roles ──> provider clients

one request
└── Run
    ├── CustomerSupportAgent
    │   ├── HelpCenterLookupTool
    │   └── ResearchAgent subagent (model-directed)
    └── sessions, resources, usage, events, and terminal result

one deterministic request
└── Run ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent
```

## Models are selected by role

An agent names a logical role such as `customer_support`, not a vendor model. `models.yml` maps that stable application vocabulary to a canonical target:

```yaml
models:
  customer_support:
    target: openai:gpt-5
```

Dotted roles inherit from the nearest registered parent. `ResearchAgent` can request `customer_support.research` and initially use the `customer_support` profile; registering `customer_support.research` later specializes it. Per-invocation profile overrides can vary a request without mutating the registry or agent class. Because an override can select a different registered provider, model, and settings, it is trusted application configuration and must be constructed or allowlisted by the application rather than copied from unchecked request data.

The provider performs model I/O. `LittleGhost::Models` resolves application intent into a `LittleGhost::Model`, which carries the provider, target, settings, details, and role for a run.

## Agents declare behavior

An agent class declares application behavior:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model "customer_support"
  system_prompt "Answer clearly. Check the help center before stating company guidance."
  tools HelpCenterLookupTool
  subagent ResearchAgent, kind: "research"
end
```

The class-level DSL is inheritable. It can declare prompts, limits, callbacks, tool classes, structured results, context management, skills, and delegation. A capability mixin may be included in `LittleGhost::Agent`, but its behavior remains inactive until the corresponding DSL is called.

`CustomerSupportAgent.ask` creates a standalone, console-friendly entrypoint, builds and consumes a `LittleGhost::Run`, and returns that run. Create `CustomerSupportAgent.new` explicitly to reuse a runtime or call `#stream_ask` for the run's events. Agents built by a runtime are instead scoped to their owning run and return a `LittleGhost::RunResult` from `#call`.

That distinction explains two useful return paths:

```ruby
run = CustomerSupportAgent.ask("Can I get a refund?")
run.response       # final text from the top-level execution
run.result.output  # text, or a validated structured value when declared
```

## Runs own top-level lifecycle

A `LittleGhost::Run` owns one top-level agent or workflow execution. It opens the session, workspace, sandbox, entrypoint, and registered resources, then closes owned resources in reverse order.

The run is both executable and enumerable. `#call` consumes it; `#each` streams `LittleGhost::StreamEvent` objects. After termination, the run reports one outcome: completed, failed, partial at a deadline, or cancelled. It also exposes the final response, result, usage, and error.

An `Invocation` is the request envelope. It normalizes the current message and history, generates missing identifiers, and retains application-specific fields with indifferent string and symbol keys. Caller identity remains explicit. If session persistence needs tenant isolation, derive its actor from trusted authentication state; never trust a model-supplied or unverified request field.

## Tools are validated application boundaries

`HelpCenterLookupTool` exposes exactly one operation to the model:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  description "Look up a help center entry by topic."
  input_schema(
    type: "object",
    properties: {topic: {type: "string"}},
    required: ["topic"],
    additionalProperties: false
  )

  def call(input)
    HelpCenterRepository.fetch(input.fetch("topic"))
  end
end
```

LittleGhost validates the model's input before invoking `#call`. Hashes and arrays returned by a tool are JSON-encoded; other values become text. Expected application failures can raise `LittleGhost::ToolError`; unexpected exception messages are sanitized before they reach model context.

Validation is not authorization. A tool that reads customer records, writes files, executes processes, or calls a network service must enforce the application's trust rules itself. The built-in unrestricted sandbox executes with the Ruby process's permissions and is not a security boundary. Configure an isolated sandbox before exposing filesystem or shell tools to untrusted work.

## Subagents are model-directed delegation

Declaring `ResearchAgent` as a subagent gives `CustomerSupportAgent` a configured set of tools for spawning, messaging, interrupting, waiting for, and listing research work:

```ruby
class ResearchAgent < LittleGhost::Agent
  description "Investigates support questions that need broader research."
  model "customer_support.research"
  system_prompt "Return a concise evidence summary."
end

class CustomerSupportAgent < LittleGhost::Agent
  model "customer_support"
  tools HelpCenterLookupTool
  subagent ResearchAgent, kind: "research"
end
```

The model decides whether to delegate and how to use the returned research. Each child declares its own tools, so access remains visible at the class receiving it. Subagent work can run concurrently and respects the configured turn, concurrency, depth, and time limits. Conversations can persist when a session store exists; `persist: false` keeps a declaration invocation-local.

Use an agent as an ordinary tool with `agent_as_tool` when one request and one result is enough. Use a subagent when the parent needs an addressable worker with follow-ups, progress, interruption, or durable conversation identity.

## Workflows are application-directed composition

Some customer support requests must always be researched before a response is written. Put that invariant in Ruby rather than asking the model to remember it:

```ruby
class ResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    research = invoke(ResearchAgent).output

    invoke CustomerSupportAgent, input: <<~PROMPT
      Customer request:
      #{input.text}

      Research:
      #{research}
    PROMPT
  end
end
```

`#invoke` builds a lazy agent invocation. Calling `#output` consumes an intermediate invocation; `#perform` must return its final invocation unconsumed so LittleGhost can stream that agent to the original caller. Input, history, state, settings, cancellation, deadline, template values, and trace parentage flow through the workflow, while intermediate usage is added to the terminal result.

A workflow is an explicit entrypoint on a run:

```ruby
runtime = LittleGhost::Runtime.new(configuration: LittleGhost.configuration)
run = runtime.build_run(
  {message: "Review this unusual refund request"},
  agent_class: CustomerSupportAgent,
  entrypoint_class: ResponseWorkflow
).call

puts run.response
```

Choose a subagent when delegation is part of the model's judgment. Choose a workflow when ordering and branching are application invariants. They can coexist: `ResponseWorkflow` can always collect baseline research, while `CustomerSupportAgent` can still delegate a new question that arises while drafting the response.

## Structured results separate data from prose

An agent that feeds application code can declare a strict JSON object schema:

```ruby
class ResearchAgent < LittleGhost::Agent
  model "customer_support.research"
  result_schema(
    {
      type: "object",
      properties: {
        summary: {type: "string"},
        sources: {type: "array", items: {type: "string"}}
      },
      required: %w[summary sources],
      additionalProperties: false
    },
    name: "support_research"
  )
end
```

LittleGhost selects provider-native structured output when the resolved model advertises it, or a strict terminal tool when supported. The locally validated value is available through `RunResult#structured_result` and `RunResult#output`. Invalid output receives one repair attempt, then raises `LittleGhost::StructuredResultError`.

Use structured results when code consumes fields. Keep ordinary text when a human is the final consumer.

## Sessions preserve conversation, streams expose progress

The default session store is in-memory. A configured `SessionStore` can load history and state before an agent runs and checkpoint coherent turns as work progresses. The application must supply stable session and actor identifiers when it wants continuity and isolation.

Streams expose generic framework events rather than provider wire formats. Consumers can render text deltas, observe tool or subagent activity, collect usage, and react to terminal outcomes without coupling to OpenAI, OpenRouter, or Bedrock. The optional AG-UI adapter translates the same events at an interface boundary.

## Keep the boundary visible

The core design can be summarized as four choices:

- Put shared construction and provider policy in `providers.yml` and `models.yml`.
- Put model behavior and available capabilities on agent classes.
- Put privileged application operations behind narrow, authorized tools.
- Put mandatory ordering in workflows; leave optional delegation to subagents.

Return to [Getting Started](Getting%20Started.md) for the complete first-run setup. The API reference covers exact signatures and lifecycle details for `LittleGhost::Runtime`, `LittleGhost::Run`, `LittleGhost::Agent`, `LittleGhost::Tool`, `LittleGhost::Workflow`, and `LittleGhost::Models`.
