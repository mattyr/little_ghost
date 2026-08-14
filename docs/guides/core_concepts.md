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

Graph nodes do not receive caller history or application context unless they opt in. They still receive the original request and the outputs routed to them. Use edge input mappers to choose or redact what moves forward.

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

Use a builder when trusted runtime configuration decides the participants or routes. Each call freezes a snapshot of that definition. Ruby callbacks—and any outside objects they use—remain live application code.

## One result, including the journey

Every assembly produces the same top-level `Run` and terminal `RunResult`. Composite assemblies also record bounded semantic steps:

```ruby
run = SupportFlowGraph.ask("Why was I charged twice?")

run.response
run.result.steps
run.result.trajectory.transitions
```

This shows callers which participants ran without exposing provider-specific payloads. A Swarm or Graph may hide intermediate model events from the public stream so the response stays coherent. That is a presentation choice, not a privacy boundary: routed outputs and step summaries still exist.

The pieces now fit together: Agents define behavior. Tools connect them to Ruby. Runs record one execution. Assemblies let the system grow without changing the caller.

Continue with [Compose Agents with Assemblies](assemblies.md) to put several agents to work together. If you are ready to connect the feature to a real application, jump to [Running in Production](production.md).
