# Build AI features with LittleGhost

<hr>

**Growing in public.** LittleGhost is under active development, and interfaces may evolve between releases. Pin the gem version and review the release notes when upgrading.

<hr>

Bring agents and agentic workflows into an existing Ruby system, or use them as the core of a dedicated AI service. LittleGhost brings model providers, tools, streaming, sessions, delegation, deterministic composition, and observability together behind one coherent set of Ruby APIs.

Here is the shape of a small customer support agent. This example uses the conventional `config/little_ghost/providers.yml` and `config/little_ghost/models.yml` paths, while applications may configure either section inline or point it at another file:

```yaml
# providers.yml
providers:
  openai:
    adapter: openai
    api_key: <%= ENV.fetch("OPENAI_API_KEY") %>
```

```yaml
# models.yml
default_model: customer_support
models:
  customer_support:
    target: openai:gpt-5
```

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
  model "customer_support"
  system_prompt "Answer clearly. Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask("Can I get a refund after two weeks?")
puts run.response
# One possible response:
# Refunds are available within 30 days, so your purchase is eligible.
```

The result is a normal Ruby object. You can inspect its outcome, final response, normalized messages, token usage, and error instead of parsing provider-specific payloads.

LittleGhost keeps the model loop provider-neutral. Tools can run in parallel, mutating tools can opt into a run-wide exclusive lock, and oversized tool results are truncated to the configured limit before they enter model context. Strict result schemas, cancellation, deadlines, session checkpoints, structured events, and OpenTelemetry integration are available when an application needs them; none are required to define the first agent.

The core stays dependency-light, while provider SDKs and deployment choices remain with the application.

## How it fits together

```text
providers.yml + models.yml ──> LittleGhost.model_resolver ──> provider
                                      │
request ──> CustomerSupportAgent ──> HelpCenterLookupTool
                  │
                  └────────> ResearchAgent (when delegated)

request ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent
```

Configuration owns shared services such as model resolution, sessions, lookup paths, workspaces, sandboxes, and instrumentation. Agent classes own behavior: their logical model role, prompt, tools, limits, structured result, and delegation policy. A tool is a validated boundary around application code. A subagent lets the model delegate work within configured turn, concurrency, and depth limits; a workflow uses ordinary Ruby when your application must choose the sequence.

Applications that need custom routing can subclass `LittleGhost::ModelResolver` and install the class with `config.model_resolver`. Provider adapters similarly subclass `LittleGhost::Providers::Base`; catalog sources subclass `LittleGhost::Models::Catalog::Source`. These explicit interfaces keep runtime behavior predictable while preserving extension points.

`CustomerSupportAgent.ask(...)` creates a standalone entrypoint, consumes its run, and returns the completed `LittleGhost::Run`. Create an instance explicitly when reusing a runtime or when an interface should render progress as `LittleGhost::StreamEvent` objects:

`LittleGhost::Agent.ask("hi")` uses the built-in default model selection and the system prompt `You are a helpful agent.` for a general-purpose agent.

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

Then run `bundle install`. Built-in OpenAI-compatible, OpenRouter, Anthropic, Gemini, Vertex AI, and Amazon Bedrock integrations use Ruby's standard library and normalize responses into the same LittleGhost protocol.

By default, LittleGhost maps the `default` role to GPT-5.6 Luna. It selects the first nonblank API key from `LITTLEGHOST_OPENROUTER_API_KEY`, `LITTLEGHOST_OPENAI_API_KEY`, `OPENROUTER_API_KEY`, and `OPENAI_API_KEY`, in that order. Setting one of these keys authorizes model inputs—including prompts, conversation history, tool data, and attachments—to be sent to the selected external provider. Applications with provider or data-residency requirements should configure providers and profiles explicitly.

Provider connections and model profiles are independent. Inline declarations take precedence over an explicitly selected or conventional file, and an explicitly selected path must exist. Missing conventional files are valid and fall through to environment-based providers and the Luna profile:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
  }
  config.models = {
    customer_support: {target: "openai:gpt-5"}
  }
  config.default_model = :customer_support
end
```

Use `config.providers_path` or `config.models_path` when only one section belongs in YAML or when the files live outside the conventional directory. Application directories such as `config/little_ghost`, `app/agents`, `app/prompts`, and `app/skills` are defaults and suggested conventions, not a required project layout.

A custom resolver class owns its profiles and default role. LittleGhost constructs it with `providers:`, `provider_adapters:`, `catalog_sources:`, and `credential_resolver:`. Configuring `models`, `models_path`, or `default_model` alongside a custom resolver emits one warning and ignores those model declarations; provider configuration remains active. A `Providers::Configuration` subclass may override `credentials(provider:, adapter:, configuration:)` to resolve secrets lazily. An explicit `config.provider_credentials` callable takes precedence over that method.

By default, structured framework events have no console destination. Hosted applications can emit redacted JSON lines to standard output with `LittleGhost.configure { |config| config.log_events_to :stdout }`; `:stderr` selects standard error instead, and `nil` disables a configured destination. Event emission and severity levels are the same with or without a console destination.

Prompts can stay inline while an agent is small, then move into conventional ERB templates under `app/prompts`. Agents and tools under `app/agents` and `app/tools` are loaded from the configured application root, keeping framework setup separate from product behavior.

## Documentation

- [LittleGhost website](https://mattyr.github.io/little_ghost/) is the quickest way to meet the framework and find your next step.
- [Getting Started](docs/guides/getting_started.md) builds the customer support example from an empty application and runs it.
- [Core Concepts](docs/guides/core_concepts.md) explains models, agents, tools, delegation, workflows, sessions, and streaming through the same example.
- [API reference](rdoc-ref:LittleGhost) covers exact signatures, options, and lifecycle details.

## Contributing

LittleGhost welcomes focused contributions. See the
[contributing guide](https://github.com/mattyr/little_ghost/blob/main/CONTRIBUTING.md),
[Code of Conduct](https://github.com/mattyr/little_ghost/blob/main/CODE_OF_CONDUCT.md),
and [security policy](https://github.com/mattyr/little_ghost/blob/main/SECURITY.md).

For a local checkout:

```sh
bundle install
bundle exec rake test
bundle exec standardrb --no-fix
```

LittleGhost is licensed under the MIT License.
