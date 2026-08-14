# Compose Agents

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

Each child Agent keeps its own [prompt view](prompt_views.md). The Workflow supplies request-specific input; it does not replace that Agent's reusable system instructions.

The last child is special because its events become the Workflow's public stream. Return that `invoke` without consuming it:

```ruby
# Wrong: this returns a String after consuming the final invocation.
def perform
  invoke(CustomerSupportAgent).output
end

# Right: this returns the lazy invocation itself.
def perform
  invoke CustomerSupportAgent
end
```

The first version produces a failed top-level Run whose error is `ProtocolError`. Use `.output` only when Ruby needs an intermediate answer before choosing the next step.

### Choose a branch in Ruby

Each branch should end with its final unconsumed invocation:

```ruby
class RoutedResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    route = invoke(TriageAgent, as: :triage).output

    if route == "billing"
      invoke BillingAgent, as: :billing_response
    else
      invoke CustomerSupportAgent, as: :general_response
    end
  end
end
```

`as:` gives the child a readable participant name in steps, trajectories, and telemetry. It does not change which Assembly runs.

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

The active model sees a handoff tool listing the members it may choose next. LittleGhost accepts only the routes you declared. `max_steps` limits total member executions. `max_handoff_repeats` limits how often the same directed handoff, such as triage to billing, may repeat.

Swarm members must be Agents, so each transition stays a direct model-to-model handoff. Caller history and application context are opt-in for each member. Handoff messages come from a model; never treat them as permission to read data or perform an action.

Opt in only for a member that needs the data:

```ruby
member AccountAgent, history: true, context: true
```

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
```

Conditions and input mappers read an immutable `Graph::State`. At most one conditional edge may match. If several match, LittleGhost raises `AssemblyRoutingError` instead of guessing which one wins. One unconditional edge can catch the request when none match.

Graph nodes start without caller history or application context. They still receive the original input or the output routed from an earlier node. Map or redact that data before it moves to a provider or participant that should see less.

Opt in for a trusted node when it needs caller context:

```ruby
node :account_lookup, AccountLookupAgent, context: true
```

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

An error edge can send an expected failure to a recovery Assembly. Call `validate!` before the first run.

Once the topology grows, `InvestigationGraph.to_mermaid` returns Mermaid diagram source for the routes you declared. Render it in a Mermaid-aware editor or documentation page when a picture makes the graph easier to review.

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

Retries start at zero. When `retries` is greater than zero, `retry_on` must list the exception classes that are safe to try again. LittleGhost does not retry every failure by default.

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

An Assembly can also become an Agent tool:

```ruby
class SupportCoordinatorAgent < LittleGhost::Agent
  assembly_as_tool InvestigationGraph,
    name: "investigate_support_request",
    preserve_context: false
end
```

The nested assembly receives the parent Tool's current working state. That state may include values restored from a Session. `preserve_context` controls conversation history only: when it is false, working state still passes to the nested assembly. Any nested Tool doing privileged work must authorize with values the application established for the current request or checked again after loading.

## Reach for builders when definitions are dynamic

Classes are the preferred form in application code. Use a builder when trusted application configuration decides the nodes or routes:

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

Each builder uses the same declarations as its matching class. The builder stays editable, but each run gets a fixed copy of its current definition. Later edits affect later runs. Ruby callbacks still see any application objects they captured.

Continue with [Prompts as Views](prompt_views.md) to give each Agent's growing instructions and shared prompt pieces a natural home.
