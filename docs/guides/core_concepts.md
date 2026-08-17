# Core Concepts

Build one model-driven behavior in a Ruby class, then call it like Ruby. That is the idea LittleGhost grows from.

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly."
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask("Where is my order?")
run.response
```

From there, add only what the work needs. Give the agent a tool. Let it ask a specialist for help. Or coordinate several agents while the rest of your application keeps making the same call.

## An Agent owns one model loop

An **Agent** defines one model-driven behavior. It chooses the model, supplies the instructions and tools, and carries one request through to an answer.

The class holds the behavior you want to reuse. Each call brings its own input, history, context, settings, and attachments. Request data never needs to live on the class.

```text
CustomerSupportAgent
├── model selection
├── system prompt
├── HelpCenterLookupTool
└── limits and optional capabilities
```

An Agent can return text or checked, structured data. Later, you can add streaming, sessions, or callbacks. None of them are required to begin.

## A Tool connects the model to Ruby

A **Tool** is one focused thing an agent can ask your application to do. It has a name, a description, an input schema, and the Ruby code that does the work.

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
    {"refunds" => "Refunds are available within 30 days."}
      .fetch(input.fetch("topic"))
  end
end
```

LittleGhost checks the model's arguments, calls the tool, and gives the result back to the model. The schema checks shape, not permission. Authorize sensitive reads and actions inside the tool with trusted application context.

## A Run owns one top-level execution

Every `.ask` or `.stream_ask` creates a **Run**. Think of it as the record of one trip through LittleGhost. It opens what the request needs, records how the work ended, and closes the resources it owns.

```ruby
run = CustomerSupportAgent.ask("Where is order 481?")

run.completed? # => true
run.response
# One possible response: Order 481 is out for delivery.
run.usage      # => normalized token usage
run.result     # => the complete LittleGhost::RunResult
```

The Agent defines reusable behavior; the Run records what happened this time.

### Follow one request

One Run owns the trip from request to result:

```text
Run
├── Invocation: caller input, history, and application context
├── RunContext: mutable working state for this execution
└── Agent and Tools ──> RunResult
```

An **Invocation** is the request in LittleGhost's standard shape. Its `context` contains current request values supplied by your application. A Tool can read those values through `run.invocation.context` when it authorizes work.

The **RunContext** carries mutable working state in `context.state`. At the top level, saved Session state is loaded first, then current Invocation context is added. Child Assemblies may receive a copy, a mapped value, or no context at all. Recheck saved values before using them for permission decisions.

A Tool's **Binding** gives the Tool access to objects created for this run, including the Agent, Run, workspace, and sandbox. These objects are separate from the arguments chosen by the model. [Workspaces, Sandboxes, and Tools](sandboxing.md) explains which operations actually cross the sandbox boundary.

The final **RunResult** keeps the complete assembly result. Its `text` is the final text answer. Its `output` returns structured data when the Agent declared a result schema, and text otherwise. The top-level `Run#response` is always the caller-facing text.

### See how a call ended

Top-level calls normally return a Run, even when execution fails. The terminal event carries the same outcome when you stream:

| What happened | Run outcome | Terminal event | What Ruby does |
| --- | --- | --- | --- |
| The assembly completed | `completed` | `:run_stop` | Returns the Run |
| Model, provider, or assembly execution failed | `failed` | `:run_error` | Returns the Run; inspect `run.error` |
| The deadline stopped work | `partial` | `:run_partial` | Returns the Run with any response produced so far |
| Cancellation stopped work | `cancelled` | `:run_cancel` | Returns the Run without a response |
| Tool input or a `ToolError` failed | The model may recover | No terminal event by itself | Gives a safe error result back to the model |
| Input, configuration, or resources failed before a Run could start | No Run exists | None | Raises the exception |

Unexpected Tool exception messages are hidden from the model. The original exception remains available to trusted application callbacks and diagnostics.

Failures while closing resources, delivering events, or reporting instrumentation sit outside the normal result path. They raise a Ruby exception because LittleGhost can no longer promise that it delivered a clean ending. [Running in Production](production.md) covers that boundary where applications supervise and shut down work.

## An Assembly can look like one Agent

One model loop is not always enough. LittleGhost calls any unit that a caller can invoke like an Agent an **Assembly**.

An Agent is the smallest Assembly. Workflow, Swarm, and Graph coordinate several participants while preserving the same entrypoints:

```ruby
CustomerSupportAgent.ask(question)
ResponseWorkflow.ask(question)
ProblemSolverSwarm.ask(question)
SupportFlowGraph.ask(question)
```

That shared calling style is what makes composition feel natural. A controller, job, or CLI does not need to know whether one Agent answered or a whole support process worked together.

## Choose who controls the next step

The coordination types differ mainly in who decides what happens next:

| Need | Choose | Who controls the next step? |
| --- | --- | --- |
| One model-driven behavior | Agent | The active model loop |
| A model should delegate a named task | Subagent | The parent model |
| Ruby should enforce ordering or branching | Workflow | The workflow's Ruby code |
| Specialists should choose permitted handoffs | Swarm | The active agent |
| Allowed routes should be visible in advance | Graph | Declared nodes and edges |

### Subagents bring in a specialist

A **subagent** is a specialist that a parent Agent can call for help. The parent model chooses when to delegate, reads the result, and then continues its own answer.

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  subagent ResearchAgent, kind: "research"
end
```

Use a subagent when delegation is part of one model's decision-making. Use a Workflow when application code must guarantee that a step happens.

### Workflows make Ruby the coordinator

A **Workflow** coordinates work with ordinary Ruby. Its `perform` method can call an Agent or another Assembly, read a result, choose a branch, or run independent steps together.

`invoke` prepares a lazy child call. Reading `.output` runs an intermediate child. Return the final `invoke` itself, without reading its output, so that answer can stream to the caller.

```ruby
class ResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    research = invoke(ResearchAgent).output
    invoke CustomerSupportAgent, input: <<~PROMPT
      #{input.text}

      Research:
      #{research}
    PROMPT
  end
end
```

Workflow children receive the caller's history and application context by default. Pass `history: []`, `context: {}`, or redacted values when a participant should receive less.

### Swarms let agents hand work to one another

A **Swarm** is a group of Agents that can hand work to one another. One member is active at a time. It can answer the caller or choose one of its allowed specialists.

```ruby
class ProblemSolverSwarm < LittleGhost::Swarm
  member TriageAgent
  member BillingAgent
  member AccountAgent

  start TriageAgent
  handoff TriageAgent, to: [BillingAgent, AccountAgent]
end
```

A Swarm is intentionally agent-to-agent. Its members are Agents, not other kinds of Assembly. Caller history and application context stay hidden unless a member opts in. Treat every handoff message as untrusted model input.

### Graphs make routes visible

A **Graph** connects named Assembly nodes with declared edges. Nodes can contain Agents, Workflows, Swarms, or other Graphs.

```ruby
class SupportFlowGraph < LittleGhost::Graph
  node :triage, TriageAgent
  node :billing, BillingAgent
  node :general, CustomerSupportAgent
  node :respond, CustomerSupportAgent

  start :triage
  edge :triage, :billing do |state|
    state.result(:triage).output == "billing"
  end
  edge :triage, :general
  edge :billing, :respond
  edge :general, :respond
  finish :respond
end
```

Graph nodes do not receive caller history or application context unless they opt in. They receive the original task and immediate predecessor results as labeled context.

Multiple unconditional edges fan out in parallel and converge at their first unambiguous common successor. Array endpoints declare an explicit fan-out or wait-for-all fan-in. Edge and node input mappers receive immutable `Graph::State` and can replace the default input with an exact value.

Only connect parallel participants allowed to receive both the original request and source output. A trusted redaction node before the fan-out can narrow the source output. Give the graph a redacted request from trusted application code when the original also needs narrowing.

## Class definitions first, builders when needed

Named classes are the default way to organize reusable behavior. They are readable, load through normal Ruby conventions, and give the coordination style a visible name such as `ResponseWorkflow` or `SupportFlowGraph`.

Every assembly class can also produce a mutable builder:

```ruby
graph = SupportFlowGraph.to_builder
graph.node :audit, AuditAgent
graph.edge :respond, :audit
graph.finish :audit
graph.validate!
run = graph.ask("Review order 481")
```

Use a builder when trusted application configuration decides the participants or routes. Each run gets a fixed copy of the builder as it looked when the run began, so later edits affect later runs. Ruby callbacks still see any application objects they captured.

## One result, including the journey

Every assembly produces the same top-level `Run` and final `RunResult`. Composite assemblies also keep a size-limited record of the participants that ran:

```ruby
run = SupportFlowGraph.ask("Why was I charged twice?")

run.response
run.result.steps
run.result.trajectory.transitions
```

This shows callers which participants ran without including raw provider responses. The ordinary Swarm or Graph event projection keeps the final response coherent, but that presentation choice is not a privacy boundary. Routed outputs and step summaries still exist.

Composite assemblies also emit `:agent_stream` events by default so an interface can follow the live work from every Agent. Each event carries source metadata and a detached, deeply immutable snapshot of the Agent event. Invocation-start events also carry the routed input snapshot.

Pass `include_agent_events: false` when only the ordinary public stream is needed. The contextual view includes sensitive and untrusted inputs, reasoning, tool data, outputs, and errors. Filter it before it crosses a logging, transport, or user-interface boundary. [Compose Agents](assemblies.md) shows the complete pattern.

The pieces now fit together: Agents define behavior. Tools connect them to Ruby. Runs record one execution. Assemblies let the system grow without changing the caller.

Continue with [Compose Agents](assemblies.md) to put several agents to work together. If you are ready to connect the feature to a real application, jump to [Running in Production](production.md).
