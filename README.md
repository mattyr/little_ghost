# Build AI features with LittleGhost

<hr>

**Growing in public.** LittleGhost is under active development, and interfaces may evolve between releases. Pin the gem version and review the release notes when upgrading.

<hr>

Build an agent inside an existing Ruby system, or use LittleGhost as the core of a dedicated AI service. An agent is a reusable Ruby class that gives one model a prompt, tools, limits, and a model selection. LittleGhost connects that class to providers, streaming, sessions, delegation, and observability.

Set `OPENAI_API_KEY`, then paste this customer support agent into a Ruby console or file. It selects a model directly and exposes one validated application tool:

```ruby
require "little_ghost"

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
      .fetch(input.fetch("topic"), "No help center entry found.")
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model "openai:gpt-5.6-luna"
  system_prompt "Answer clearly. Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask("Can I get a refund after two weeks?")
puts run.response
# One possible response:
# Refunds are available within 30 days, so your purchase is eligible.
```

The completed `LittleGhost::Run` exposes its outcome, final response, normalized messages, token usage, and terminal error. Streaming callers receive `LittleGhost::StreamEvent` objects instead of provider-specific payloads:

```ruby
CustomerSupportAgent.stream_ask("Can I get a refund?").each do |event|
  print event.data.fetch(:text) if event.type == :text_delta
end
```

## How the pieces fit

One agent is the smallest useful LittleGhost application. A request creates a run, the agent may call a tool or delegate to a subagent, and the run records the outcome:

```text
provider connections + model selections ──> ModelResolver ──> provider
                                               │
request ──> CustomerSupportAgent ──> HelpCenterLookupTool
                  │
                  └────────> ResearchAgent subagent
```

When one model loop is not enough, LittleGhost calls the larger callable unit an **assembly**. An assembly may be one agent or a coordinated group that still looks like one agent to its caller:

```text
request ──> CustomerSupportAgent

request ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent

request ──> ProblemSolverSwarm ──> TriageAgent ──handoff──> BillingAgent

request ──> SupportFlowGraph ──> TriageAgent ──edge──> ResponseAgent
```

A `Workflow` uses ordinary Ruby to enforce ordering and branching. A `Swarm` lets configured agents hand the request directly to one another. A `Graph` follows application-declared nodes and edges when the allowed paths should be visible in advance. These types share `ask` and `stream_ask`, so callers can depend on one entrypoint contract while the implementation grows.

Class definitions are the default way to organize agents and assemblies. Builder objects support definitions whose participants or topology are discovered at runtime; the Core Concepts guide introduces them after the class-based forms.

Each top-level execution owns one run lifecycle. The run checkpoints session state, closes its resources, aggregates usage, and emits framework events regardless of which assembly type is the entrypoint.

## Installation and configuration

LittleGhost requires Ruby 3.3 or newer. Add it to your bundle:

```ruby
gem "little_ghost"
```

Then run `bundle install`. Built-in OpenAI-compatible, OpenRouter, Anthropic, Gemini, Vertex AI, and Amazon Bedrock integrations use Ruby's standard library and normalize responses into the same protocol.

Configuration does not require a particular directory layout. Provider connections and model profiles resolve independently in this order:

1. An inline `config.providers` or `config.models` declaration.
2. The corresponding explicit `config.providers_path` or `config.models_path`.
3. The optional conventional file under `config/little_ghost/`.
4. Environment-based provider selection and the built-in `default` profile.

An explicit path must exist. A missing conventional file is valid. The conventional form keeps connection policy separate from model roles:

```yaml
# config/little_ghost/providers.yml
providers:
  openai:
    adapter: openai
    api_key: <%= ENV.fetch("OPENAI_API_KEY") %>
```

```yaml
# config/little_ghost/models.yml
default_model: customer_support
models:
  customer_support:
    target: openai:gpt-5.6-luna
```

By default, LittleGhost maps `default` to GPT-5.6 Luna. It configures conventional OpenRouter and OpenAI connections from nonblank `LITTLEGHOST_OPENROUTER_API_KEY`, `LITTLEGHOST_OPENAI_API_KEY`, `OPENROUTER_API_KEY`, and `OPENAI_API_KEY` values; that order determines the default when more than one provider is available. Model inputs—including prompts, history, tool data, and attachments—leave the application for the selected external provider. Configure providers explicitly when provider choice or data residency matters.

Applications that need custom routing can subclass `LittleGhost::ModelResolver` and install the class with `config.model_resolver`. A custom resolver owns its profiles and default role; configuring `models`, `models_path`, or `default_model` at the same time is an error. Provider configuration remains available to the resolver.

LittleGhost runs inside the surrounding Ruby process; it does not prescribe an HTTP server, CLI, job system, or application layout. `config/little_ghost`, `app/agents`, `app/assemblies`, `app/prompts`, `app/tools`, and `app/skills` are optional conventions. Keep agent classes in `app/agents`; workflow, swarm, and graph classes conventionally live in `app/assemblies`. Names should reveal the type, such as `DevelopmentWorkflow`, `ProblemSolverSwarm`, or `SupportFlowGraph`.

## Documentation

- [Getting Started](docs/guides/getting_started.md) builds and streams the customer support example.
- [Core Concepts](docs/guides/core_concepts.md) starts with one agent, then introduces assemblies, delegation, workflows, swarms, graphs, and dynamic builders.
- [API reference](rdoc-ref:LittleGhost) covers exact signatures, options, and lifecycle behavior.

## Contributing

See the [contributing guide](https://github.com/mattyr/little_ghost/blob/main/CONTRIBUTING.md), [Code of Conduct](https://github.com/mattyr/little_ghost/blob/main/CODE_OF_CONDUCT.md), and [security policy](https://github.com/mattyr/little_ghost/blob/main/SECURITY.md).

```sh
bundle install
bundle exec rake test
bundle exec standardrb --no-fix
```

LittleGhost is licensed under the MIT License.
