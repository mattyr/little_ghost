# Build AI features that feel at home in Ruby

> **Using a coding agent?** Start with
> [`llms.txt`](https://mattyr.github.io/little_ghost/llms.txt) for a concise map
> of the guides and API. [`llms-full.txt`](https://mattyr.github.io/little_ghost/llms-full.txt)
> contains the complete documentation in one file.

LittleGhost is a Ruby library for building AI features with agents and composable assemblies. With `OPENROUTER_API_KEY` set, start with one class, give it a prompt, and call it like the rest of your application code:

```ruby
require "little_ghost"

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end

run = CustomerSupportAgent.ask("Draft a friendly greeting for a customer.")
run.response
# One possible response: Hi! How can I help today?
```

That small definition is already a complete agent. LittleGhost makes the model call, tracks usage, supports streaming, and closes the resources it creates for the request. Add a tool when the agent needs something from your application. Bring in more agents when the work grows.

Model requests may send system instructions, caller input, conversation history,
Tool results, and attachments to the selected provider. Model wording can vary
between runs. [Models and Providers](docs/guides/models_and_providers.md) explains
how to choose where each Agent sends its requests.

## Install the gem

LittleGhost requires Ruby 3.3 or newer. Add it to your bundle and provide a provider credential:

```ruby
gem "little_ghost"
```

```sh
$ bundle install
$ export OPENROUTER_API_KEY="..."
```

OpenRouter keeps the first setup to one credential. It is not required: LittleGhost also includes adapters for OpenAI-compatible APIs, Anthropic, Gemini, Vertex AI, and Bedrock. [Running in Production](docs/guides/production.md) shows how to configure providers and give model choices application-facing names.

LittleGhost runs inside your Ruby process. Use it from a controller, job, CLI, or service. If you want a conventional layout, start with `app/agents`, `app/assemblies`, `app/prompts`, and `app/tools`.

## Give an agent real capabilities

Tools let an agent call focused parts of your application:

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
      .fetch(input.fetch("topic"), "No help center entry found.")
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end
```

The schema checks the shape of the input. Your Ruby code still decides whether
the operation is allowed. The result goes back to the model as context.

An ordinary Tool runs in your Ruby process. When a Tool needs files or child
processes, it can delegate that work through a Sandbox. Code mode goes one step
further: a sandboxed interpreter can compose several Tools, while every Tool
call still returns to your Ruby Tool for validation and permission checks.

## Grow without changing the caller

An **agent** owns one model loop. An **assembly** is one or more agents working as a unit. You call either one the same way:

```ruby
CustomerSupportAgent.ask(question)
ResponseWorkflow.ask(question)
ProblemSolverSwarm.ask(question)
SupportFlowGraph.ask(question)
```

Choose the coordination style that matches who should control the next step:

- A **subagent** lets a model delegate an addressable task.
- A **workflow** uses ordinary Ruby for ordering and branching.
- A **swarm** lets configured agents choose permitted handoffs.
- A **graph** makes allowed routes explicit as nodes and edges.

A Workflow or Graph can contain agents, other assemblies, or both. Named classes are the clearest place to begin. Builders are there when your application discovers the participants or routes at runtime.

```text
request ──> CustomerSupportAgent

request ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent

request ──> ProblemSolverSwarm ──> TriageAgent ──handoff──> BillingAgent

request ──> SupportFlowGraph ──> TriageAgent ──edge──> ResponseAgent
```

The result stays familiar too. Every call returns a `Run` with the response,
outcome, usage, and any final error. A coordinated assembly also records which
participants ran. Use `.stream_ask` to watch the work as it happens.

LittleGhost is pre-1.0. Pin the gem version and review release notes before
upgrading, because interfaces may change between releases.

## Keep going

- [Getting Started](docs/guides/getting_started.md) takes you from installation to a tool-backed, streaming agent.
- [Core Concepts](docs/guides/core_concepts.md) builds the mental model from Agent to Assembly.
- [Models and Providers](docs/guides/models_and_providers.md) gives shared model choices application-facing names.
- [Prompts as Views](docs/guides/prompt_views.md) gives growing instructions, shared pieces, and application values a natural home.
- [Tools](docs/guides/tools.md) explains how models call focused Ruby operations.
- [Structured Results and Content](docs/guides/structured_outputs_and_content.md) covers checked result shapes, images, and documents.
- [Compose Agents](docs/guides/assemblies.md) walks through workflows, swarms, graphs, nesting, and builders.
- [Skills](docs/guides/skills.md) organizes reusable instructions and supporting resources.
- [Workspaces and Sandboxes](docs/guides/sandboxing.md) gives files and child processes a deliberate place to run.
- [Code Mode](docs/guides/code_mode.md) lets a model compose Tools in sandboxed Ruby or optional JavaScript.
- [Integrations](docs/guides/integrations.md) connects MCP, AG-UI, and OpenTelemetry.
- [Running in Production](docs/guides/production.md) covers configuration, saved conversations, supervision, and observability.
- [API reference](rdoc-ref:LittleGhost) provides exact method signatures and ownership rules.

### For contributors

See the [contributing guide](https://github.com/mattyr/little_ghost/blob/main/CONTRIBUTING.md), [Code of Conduct](https://github.com/mattyr/little_ghost/blob/main/CODE_OF_CONDUCT.md), and [security policy](https://github.com/mattyr/little_ghost/blob/main/SECURITY.md).

```sh
$ bundle install
$ bundle exec rake test
$ bundle exec standardrb --no-fix
```

LittleGhost is available under the MIT License.
