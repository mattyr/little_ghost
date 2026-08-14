# Compose Agents with Assemblies

An Assembly lets several participants answer through the same familiar calls as one Agent. This guide grows the customer-support example through each coordination style, then shows how to nest and construct assemblies dynamically.

## Start with the shared contract

Callers do not need a branch for each implementation:

```ruby
entrypoint = urgent? ? EscalationWorkflow : CustomerSupportAgent
run = entrypoint.ask(question)
```

`Agent`, `Workflow`, `Swarm`, and `Graph` all answer through the Assembly calling style. They differ in how they coordinate work, not in how your application calls them.

## Use a Workflow for explicit application logic

A Workflow's `perform` method is ordinary Ruby. Inside it, `invoke` prepares a child call. Read `.output` when you need an intermediate answer. Return the final `invoke` call untouched so its response can stream to the caller.

```ruby
class ResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    research = invoke(ResearchAgent).output

    invoke CustomerSupportAgent, input: <<~PROMPT
      #{input.text}

      Verified research:
      #{research}
    PROMPT
  end
end

run = ResponseWorkflow.ask("Why is transfer 481 pending?")
run.response
```

Every participant passed to `invoke` can be an Agent or another Assembly. By default, each child receives the caller's history and application context. Pass `history: []`, `context: {}`, or redacted values when a child should see less.

### Run independent work in parallel

Use `parallel` when several inputs can be processed independently:

```ruby
class InvestigationWorkflow < LittleGhost::Workflow
  private

  def perform
    findings = parallel(
      invoke(LedgerResearchAgent),
      invoke(PolicyResearchAgent),
      max_concurrency: 2
    )

    invoke CustomerSupportAgent, input: <<~PROMPT
      #{input.text}

      Findings:
      #{findings.join("\n")}
    PROMPT
  end
end
```

`max_concurrency` limits how many calls run at once. Each one gets its own copy of the workflow context. Cancellation still depends on the provider or tool noticing its token or deadline.

## Use a Swarm for specialist handoffs

A Swarm keeps one Agent active at a time. You decide which specialists it may hand work to:

```ruby
class ProblemSolverSwarm < LittleGhost::Swarm
  member TriageAgent
  member BillingAgent
  member AccountAgent

  start TriageAgent
  handoff TriageAgent, to: [BillingAgent, AccountAgent]
  handoff BillingAgent, to: TriageAgent
  handoff AccountAgent, to: TriageAgent

  max_steps 10
  max_handoff_repeats 2
end
```

The active model requests a handoff through a reserved tool. LittleGhost accepts only the routes you declared. Step and repeat limits keep the conversation from circling forever.

Swarm members must be Agents, so each transition stays a direct model-to-model handoff. Caller history and application context are opt-in for each member. Handoff messages come from a model; never treat them as permission to read data or perform an action.

Intermediate model text stays out of the caller-facing stream, leaving one coherent public answer. This is not a privacy boundary. The next member receives the handoff, and the result keeps a bounded summary of the journey.

## Use a Graph for guided routes

A Graph names the possible stops and the routes between them. Start with a conditional route before adding parallel branches:

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

SupportFlowGraph.validate!
SupportFlowGraph.to_mermaid
```

Conditions and input mappers read an immutable `Graph::State`. Exactly one conditional edge may match. If several match, LittleGhost raises `AssemblyRoutingError` instead of guessing which one wins. One unconditional edge can catch the request when none match.

Graph nodes start without caller history or application context. They still receive the original input or the output routed from an earlier node. Map or redact that data before it moves to a provider or participant that should see less.

### Fork and join bounded parallel paths

Use a fork when one result should start several independent branches. A join brings their answers back together:

```ruby
class InvestigationGraph < LittleGhost::Graph
  node :triage, TriageAgent
  node :ledger, LedgerResearchAgent
  node :policy, PolicyResearchAgent
  node :respond, CustomerSupportAgent

  start :triage
  fork :triage, to: [:ledger, :policy], max_concurrency: 2
  join(
    [:ledger, :policy],
    to: :respond,
    input: ->(state) { state.branch_results.transform_values(&:output) }
  )
  finish :respond
end
```

An error edge can send an expected failure to a recovery Assembly. Call `validate!` before the first run, and use `to_mermaid` to see the same routes as a diagram.

## Make retries safe

Workflow calls, Swarm members, and Graph nodes can set timeouts and retries. Use them for work that can safely be attempted again:

```ruby
invoke(
  ResearchAgent,
  timeout: 15,
  retries: 2,
  retry_on: [LittleGhost::ProviderError],
  retry_delay: 0.25
)
```

A timeout asks the running code to stop; it cannot forcibly end arbitrary Ruby or provider work. A retry repeats the whole child step. Retry only selected failures, and make sure repeated external actions are safe.

## Inspect what the assembly did

A composite result remembers the steps it took. `trajectory` lets you explore them:

```ruby
run = InvestigationGraph.ask("Why is transfer 481 pending?")
trajectory = run.result.trajectory

trajectory.each { |step| puts "#{step.participant}: #{step.status}" }
trajectory.transitions
ledger = trajectory.find { |step| step.participant == "ledger" }
policy = trajectory.find { |step| step.participant == "policy" }
trajectory.concurrent?(ledger.id, policy.id)
```

Step outputs and buffered events have size limits. Use your application's instrumentation when trusted operators need deeper diagnostics.

## Compose assemblies inside assemblies

Workflow and Graph participants accept any Assembly definition:

```ruby
class ResolutionGraph < LittleGhost::Graph
  node :investigate, InvestigationWorkflow
  node :resolve, ProblemSolverSwarm

  start :investigate
  edge :investigate, :resolve
  finish :resolve
end
```

An Assembly can also become an Agent tool with `assembly_as_tool`. The nested assembly always receives the application's invocation context. It receives conversation history only with `preserve_context: true`. Turning that option off does not remove application context, so nested tools must still authorize from trusted values.

## Reach for builders when definitions are dynamic

Classes are the preferred form in application code. Use a builder when trusted runtime configuration decides the nodes or routes:

```ruby
graph = LittleGhost::GraphBuilder.new(
  id: "support_flow",
  description: "Routes customer support requests"
)

graph.node :triage, TriageAgent
graph.node :respond, CustomerSupportAgent
graph.start :triage
graph.edge :triage, :respond
graph.finish :respond
graph.validate!

run = graph.ask("Where is my order?")
```

Each builder uses the same declarations as its matching class. The builder stays editable, but LittleGhost takes a snapshot at the start of each run. Later edits affect later runs. Ruby callbacks still use any outside objects they captured.

Continue with [Running in Production](production.md) to configure model roles, reuse runtimes, preserve sessions, supervise execution, and connect observability.
