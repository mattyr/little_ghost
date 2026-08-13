# Core Concepts

Start with one agent. In LittleGhost, an **agent** is a reusable Ruby definition for one model loop: it selects a model, supplies instructions, exposes tools, and decides when the model has finished answering one request.

```text
shared configuration
└── ModelResolver ── resolves model selections ──> provider clients

one request
└── Run
    ├── CustomerSupportAgent
    │   ├── HelpCenterLookupTool
    │   └── ResearchAgent subagent (model-directed)
    └── sessions, resources, usage, events, and terminal result
```

The sections below build outward from that unit. After the agent, the guide introduces its model, tools, and run lifecycle. It then names an **assembly**: anything a caller can invoke like one agent, including coordinated workflows, swarms, and graphs.

## Agents declare one model-driven behavior

An agent class keeps the behavior for one application role together:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model :customer_support
  system_prompt "Answer clearly. Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end
```

The class-level DSL is inheritable. It can declare prompts, limits, callbacks, tool classes, structured results, context management, skills, and delegation. Capabilities remain inactive until their corresponding DSL is called.

`CustomerSupportAgent.ask` creates a standalone entrypoint, consumes one `LittleGhost::Run`, and returns that run. `CustomerSupportAgent.stream_ask` creates the same entrypoint and yields events while it works. Create `CustomerSupportAgent.new(runtime:)` explicitly when several calls should reuse one runtime.

```ruby
run = CustomerSupportAgent.ask("Can I get a refund?")
run.response       # final text from the top-level execution
run.result.output  # text, or a validated structured value when declared
```

## Models can be selected directly or by role

An agent can name a canonical target directly when the choice belongs beside its behavior:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openai:gpt-5.6-luna"
end
```

It can also attach trusted model settings without defining a shared profile:

```ruby
class DeliberateSupportAgent < LittleGhost::Agent
  model(provider: "openai", model: "gpt-5.6-luna", reasoning_effort: "high")
end
```

In both forms, `provider` is the name of a configured connection. A role such as `customer_support` adds stable application vocabulary when several agents or deployments should share routing policy:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
  }
  config.models = {
    customer_support: {target: "openai:gpt-5.6-luna"}
  }
end
```

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model :customer_support
end
```

Strings and symbols without a colon are roles; strings containing a colon are canonical targets; mappings require `provider` and `model`, with remaining keys treated as model settings. Role names cannot contain a colon. Direct targets and mappings bypass role inheritance and overlays.

Dotted roles inherit from the nearest registered parent. `ResearchAgent` can request `customer_support.research` and initially use the `customer_support` profile; registering `customer_support.research` later specializes it. A resolver caller may pass an explicit `profiles:` overlay without mutating the configured profiles or agent class. Because an overlay can select a different registered provider, model, and settings, it is trusted application configuration and must be constructed or allowlisted by the application rather than copied from unchecked request data. The base resolver does not inspect application-specific invocation fields.

The provider performs model I/O. `LittleGhost::ModelResolver` resolves application intent into a `LittleGhost::Model`, which carries the provider, target, settings, details, and role for a run.

## Runs own top-level lifecycle

A `LittleGhost::Run` owns one top-level execution. It opens the session, workspace, sandbox, agent entrypoint, and registered resources, then closes owned resources in reverse order. Later sections show how the same lifecycle can own a coordinated entrypoint.

The run is both executable and enumerable. `#call` consumes it; `#each` streams `LittleGhost::StreamEvent` objects. After termination, the run reports one outcome: completed, failed, partial at a deadline, or cancelled. It also exposes the final response, result, usage, and error.

Long-lived services can supervise a run without making their request thread own its execution:

```ruby
execution = CustomerSupportAgent.new.start_execution(
  message: "Investigate transfer 481"
) do |event|
  event_buffer << event
end

execution.interrupt_response(message: "Include the latest ledger entry")
run = execution.wait(deadline: Time.now + 30)
```

`LittleGhost::Execution` owns the worker, preserves request-scoped execution state, and coordinates cancellation, interruptions, waiting, and bounded shutdown. The underlying run still owns agent resources and its terminal outcome. Event consumers run on the worker thread. Applications should keep them thread-safe and avoid blocking indefinitely.

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

A tool can return a `LittleGhost::Tool::ExecutionResult` with `companion_content` when the next model request also needs text, images, or documents. LittleGhost keeps the ordinary tool result intact, then appends each tool's companion blocks as a transient user message in tool-call order. Session persistence omits those transient messages. Tool-use, tool-result, and reasoning blocks are rejected as companion content.

Validation is not authorization. A tool that reads customer records, writes files, executes processes, or calls a network service must enforce the application's trust rules itself. The built-in unrestricted sandbox executes with the Ruby process's permissions and is not a security boundary. Configure an isolated sandbox before exposing filesystem or shell tools to untrusted work.

## Assemblies let coordination look like one agent

An **assembly** is any LittleGhost entrypoint that a caller can use like one agent. `CustomerSupportAgent` is therefore the smallest assembly: it contains one agent and one model loop.

When a feature needs several agents, three coordination classes preserve that same caller interface:

- A `Workflow` uses Ruby code to enforce ordering, branching, and parallel work.
- A `Swarm` lets configured agents choose direct handoffs to one another.
- A `Graph` follows named nodes and application-declared edges.

```ruby
CustomerSupportAgent.ask("Can I get a refund?")
ResponseWorkflow.ask("Can I get a refund?")
ProblemSolverSwarm.ask("Can I get a refund?")
SupportFlowGraph.ask("Can I get a refund?")
```

Each call returns a top-level `LittleGhost::Run`, and each `stream_ask` yields the same event vocabulary. The caller chooses an entrypoint without needing to branch on its internal coordination style. Instances also share `call`, `stream`, `start_execution`, interruption, and `as_tool` behavior.

Keep agent definitions in `app/agents`. Put workflow, swarm, and graph definitions in `app/assemblies`, with class names ending in `Workflow`, `Swarm`, or `Graph`. The next sections explain when each form earns its name.

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

`#invoke` builds a lazy Assembly invocation, so a workflow step may be an agent, workflow, swarm, or graph. Calling `#output` consumes an intermediate invocation; `#perform` must return its final invocation unconsumed so LittleGhost can stream it to the original caller. Input, history, state, settings, cancellation, deadline, template values, and trace parentage flow through the workflow, while intermediate usage is added to the terminal result.

Unlike Graph nodes and Swarm members, each Workflow invocation receives the full caller history and application context by default. Isolated copies prevent one child from mutating a sibling's context; they do not prevent disclosure. Pass `history: []`, `context: {}`, or explicitly redacted values to `invoke` when participants use different providers or privileges.

Independent invocations can run concurrently while ordinary Ruby still controls composition:

```ruby
research, verification = parallel(
  invoke(ResearchGraph, as: :research),
  invoke(VerificationWorkflow, as: :verification),
  max_concurrency: 2
)
```

Results preserve declaration order. Each branch receives isolated application context and cooperative cancellation. `timeout:`, `retries:`, `retry_on:`, and `retry_delay:` apply to `invoke`; retries require explicit exception classes because rerunning an Assembly may repeat tool side effects.

Cancellation, deadlines, and step timeouts are cooperative. They do not forcibly stop provider or tool code, and they do not roll back external side effects. A participant must honor its cancellation token or deadline, and applications must decide whether an operation is safe to retry.

A workflow has the same entrypoint API as an agent:

```ruby
run = ResponseWorkflow.ask("Review this unusual refund request")

puts run.response
```

Choose a subagent when delegation is part of the model's judgment. Choose a workflow when ordering and branching are application invariants. They can coexist: `ResponseWorkflow` can always collect baseline research, while `CustomerSupportAgent` can still delegate a new question that arises while drafting the response.

## Swarms use direct agent handoffs

A swarm keeps one member active at a time and injects one reserved `handoff_to_agent` tool. A member either answers the caller or hands the request directly to another configured member:

```ruby
class ProblemSolverSwarm < LittleGhost::Swarm
  member TriageAgent
  member BillingAgent
  member AccountAgent
  start TriageAgent
  handoff TriageAgent, to: [BillingAgent, AccountAgent]
  max_steps 12
  max_handoff_repeats 3
end
```

Members are fresh Agent instances; unlike Workflow invocations and Graph nodes, Swarm members intentionally remain Agent-only so handoffs stay direct and local. A complete Swarm can still be used as a Workflow step, Graph node, or tool. A handoff names the next member and supplies a message plus optional JSON-like context. That context remains untrusted model-authored prompt content; it does not become trusted application state. A member cannot hand off to itself, hand off outside the allowed topology, or combine a handoff with another tool call. Without `handoff` declarations, routing remains all-to-all except self-handoffs. A member with no declared outgoing target receives no handoff tool. Invalid calls return an ordinary tool error so the model can recover. If no handoff occurs, the current member's response is final. Members receive only the current request or explicit handoff envelope by default; opt into original caller data with `history: true` or `context: true` on that member.

Potentially intermediate model text is omitted from the caller's ordinary response stream. Streams expose Assembly lifecycle events, then the final member's ordinary response events. `max_steps` bounds total work and `max_handoff_repeats` detects repeated directed transitions; either limit raises `AssemblyLimitError` when exhausted. Members also accept the shared cooperative retry and timeout options described for workflows.

## Graphs guide serial and parallel paths

A graph names Assembly nodes and directed edges. Ordinary edges select exactly one next node, while explicit forks and joins add bounded parallel work without shared mutable reducers:

```ruby
class SupportFlowGraph < LittleGhost::Graph
  node :triage, TriageAgent
  node :research, ResearchAgent
  node :verify, VerificationWorkflow
  node :respond, CustomerSupportAgent

  start :triage
  fork :triage, to: [:research, :verify], max_concurrency: 2
  join [:research, :verify], to: :respond
  finish :respond
  max_steps 12
end
```

An edge condition receives immutable `Graph::State`, including the original input, history, context, step, current and previous node names, predecessors, branch results, completed results, and a routed error when present. Exactly one matching conditional edge wins; otherwise one unconditional fallback is used. An `error_edge` can route selected application errors after retries are exhausted. Cancellation, parent deadlines, and cleanup failures always remain control flow.

By default, a downstream node receives the original multimodal input plus labeled predecessor output. A join receives every branch output in declaration order. Pass `input: ->(state) { ... }` on an edge, error edge, or join to replace that mapping. Nodes receive no caller history or application context unless their declaration opts in with `history: true` or `context: true`. The original request and routed outputs still cross node and provider boundaries by default, and routing callbacks can inspect the original context through `Graph::State`; map or redact inputs explicitly when participants have different privileges. Nodes may name any Assembly type, class, builder, or immutable definition. Fork branches may follow ordinary edges before reaching their distinct declared join sources.

`validate!` catches invalid topology before model work begins, and `to_mermaid` renders a deterministic diagram. A graph suppresses intermediate ordinary model stream events, publishes lifecycle, transition, fork, join, retry, and error events, aggregates usage, and forwards only the finish node's ordinary response stream. Downstream nodes still receive routed outputs, and terminal step records retain bounded semantic outputs for callers to inspect.

Composite `RunResult` objects expose immutable `steps` and a `trajectory`. Step records include participants, attempts, timing, usage, relationships, and bounded semantic outputs without retaining transcripts or tool payloads. Swarm handoffs retain only their explicit handoff envelope. These records support assertions such as `result.trajectory.concurrent?(first_id, second_id)` without coupling tests to a tracing backend.

## Builders unlock definitions discovered at runtime

Class definitions are the default because they keep behavior, names, and topology close together. Each agent or assembly class can produce an immutable `.definition` snapshot or an independent mutable `.to_builder` variant.

Use a builder when application code discovers participants or routes at runtime. The builder records the same declaration that the class DSL would organize:

```ruby
graph = LittleGhost::GraphBuilder.new(id: "support_flow")
graph.node :triage, TriageAgent
graph.node :respond, CustomerSupportAgent
graph.start :triage
graph.edge :triage, :respond
graph.finish :respond
graph.validate!

run = graph.ask("Can I get a refund?")
```

`AgentBuilder`, `WorkflowBuilder`, `SwarmBuilder`, and `GraphBuilder` share the Assembly execution API. Builders remain mutable; each build or invocation recursively snapshots declaration containers and referenced Assembly definitions, so later builder declarations affect only future executions. Definitions are Ruby objects rather than portable JSON because conditions, callbacks, workflow bodies, factories, and resolvers may contain executable Ruby. Those closures and their external dependencies remain live trusted application code; the snapshot does not freeze state they capture.

## Assemblies can be tools

Any assembly instance supports `as_tool`. Agent classes can also declare another assembly as a tool:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  assembly_as_tool SupportFlowGraph, name: "investigate_support_case"
end
```

`assemblies_as_tools` declares several with shared options. Existing `agent_as_tool` and `agents_as_tools` remain agent-specific aliases. Composite assemblies do not accept agent-only model or tool overrides.

An assembly tool receives the invoking tool context's application state on every call. `preserve_context: false` prevents conversational history from carrying between calls; it does not suppress that application state. Nested tools must continue to authorize privileged work from trusted context rather than from model-authored input.

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

Applications that need to reconcile persisted messages with invocation history can register a `LittleGhost::Runtime::Hook` and implement `session_history`. The hook receives the run plus `stored:` and `fallback:` message collections. Return the history to use, or `nil` to defer to the next hook and ultimately the session default. This keeps application-specific reconciliation policy outside the framework session type.

Streams expose generic framework events rather than provider wire formats. Consumers can render text deltas, observe tool or subagent activity, collect usage, and react to terminal outcomes without coupling to OpenAI, OpenRouter, or Bedrock. The optional AG-UI adapter translates the same events at an interface boundary.

## Keep the boundary visible

The core design can be summarized as five choices:

- Put shared construction and provider policy in configuration; use inline declarations or independent YAML files according to the application's needs.
- Put model behavior and available capabilities on agent classes.
- Put privileged application operations behind narrow, authorized tools.
- Put imperative ordering in workflows, dynamic peer routing in swarms, and guided routing in graphs.
- Leave addressable background delegation to subagents.

Return to [Getting Started](getting_started.md) for the complete first-run setup. The API reference covers exact signatures and lifecycle details for `LittleGhost::Runtime`, `LittleGhost::Run`, `LittleGhost::Execution`, `LittleGhost::Assembly`, `LittleGhost::Agent`, `LittleGhost::Tool`, `LittleGhost::Workflow`, `LittleGhost::Swarm`, `LittleGhost::Graph`, and `LittleGhost::ModelResolver`.
