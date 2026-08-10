# Build AI features with LittleGhost

Bring agents and agentic workflows into an existing Ruby system, or use them as the core of a dedicated AI service. LittleGhost brings model providers, tools, streaming, sessions, delegation, deterministic composition, and observability together behind one coherent set of Ruby APIs.

Here is the shape of a small customer support agent. `CustomerSupportModels` keeps provider details out of agent behavior, `HelpCenterLookupTool` exposes one narrow, validated help center lookup, and `CustomerSupportAgent` brings them together:

```ruby
require "little_ghost"

class CustomerSupportModels < LittleGhost::ModelRegistry
  def initialize
    super
    provider(:openai) do |model:, **|
      LittleGhost::Providers::OpenAI.new(
        api_key: ENV.fetch("OPENAI_API_KEY"),
        model:
      )
    end
    profile "customer_support", provider: :openai, model: "gpt-5"
  end
end

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
  model "customer_support"
  system_prompt "Answer clearly. Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end

LittleGhost.configure { |config| config.models CustomerSupportModels }

run = CustomerSupportAgent.new.ask("Can I get a refund after two weeks?")
puts run.response
# One possible response:
# Refunds are available within 30 days, so your purchase is eligible.
```

The result is a normal Ruby object. You can inspect its outcome, final response, normalized messages, token usage, and error instead of parsing provider-specific payloads.

LittleGhost keeps the model loop provider-neutral. Tools can run in parallel, mutating tools can opt into a run-wide exclusive lock, and oversized tool results are truncated to the configured limit before they enter model context. Strict result schemas, cancellation, deadlines, session checkpoints, structured events, and OpenTelemetry integration are available when an application needs them; none are required to define the first agent.

The core stays dependency-light, while provider SDKs and deployment choices remain with the application.

## How it fits together

```text
application configuration ──> CustomerSupportModels ──> provider
                                      │
request ──> CustomerSupportAgent ──> HelpCenterLookupTool
                  │
                  └────────> ResearchAgent (when delegated)

request ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent
```

Configuration owns shared services such as model registries, sessions, lookup paths, workspaces, sandboxes, and instrumentation. Agent classes own behavior: their logical model role, prompt, tools, limits, structured result, and delegation policy. A tool is a validated boundary around application code. A subagent lets the model delegate work within configured turn, concurrency, and depth limits; a workflow uses ordinary Ruby when your application must choose the sequence.

`CustomerSupportAgent.new.ask(...)` consumes a run and returns the completed `LittleGhost::Run`. Use `stream_ask` when an interface should render progress as `LittleGhost::StreamEvent` objects:

```ruby
CustomerSupportAgent.new.stream_ask("Can I get a refund?").each do |event|
  print event.data[:text] if event.type == :text_delta
end
```

Applications can add a `ResearchAgent` as a subagent for open-ended investigation, or place both agents behind a deterministic `ResponseWorkflow`. The same run lifecycle checkpoints session state, closes owned resources, aggregates usage, and emits framework events in each form.

## Installation

LittleGhost requires Ruby 3.3 or newer. Add it to your bundle:

```ruby
gem "little_ghost"
```

Then run `bundle install`. Provider SDKs and OpenTelemetry exporters are optional application dependencies. The built-in OpenAI, OpenAI-compatible, OpenRouter, and Amazon Bedrock integrations normalize their responses into the same LittleGhost protocol.

Prompts can stay inline while an agent is small, then move into conventional ERB templates under `app/prompts`. Agents and tools under `app/agents` and `app/tools` are loaded from the configured application root, keeping framework setup separate from product behavior.

## Documentation

- [Getting Started](docs/guides/Getting%20Started.md) builds the customer support example from an empty application and runs it.
- [Core Concepts](docs/guides/Core%20Concepts.md) explains models, agents, tools, delegation, workflows, sessions, and streaming through the same example.
- [API reference](rdoc-ref:LittleGhost) covers exact signatures, options, and lifecycle details.

## Status

LittleGhost was extracted from Algernon, an experimental self-improving agent framework. It is functional but still early, so APIs may change before 1.0.

LittleGhost is licensed under the MIT License.

## Development

```sh
bundle install
bundle exec rake test
bundle exec standardrb --no-fix
```
