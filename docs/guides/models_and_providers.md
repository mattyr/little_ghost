# Choose Models and Providers

A model role lets application code ask for a capability such as customer
support without depending on one vendor or model identifier. A provider
connection holds the trusted configuration needed to perform that request.

## Start with one direct target

A direct target has the form `connection:model-id`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end
```

`openrouter` is the application-configured connection. The remainder is the
provider-owned model identifier. This form is useful while one Agent owns one
stable choice.

## Name the choice with a model role

Use a role when several Agents share a choice or the application must change
models without editing those Agents:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    primary: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY")
    }
  }
  config.models = {
    customer_support: {
      target: "primary:openai/gpt-5.6-luna",
      settings: {temperature: 0.2}
    }
  }
  config.default_model = :customer_support
end

class CustomerSupportAgent < LittleGhost::Agent
  model :customer_support
end
```

The role is `customer_support`; the provider connection is `primary`; the
adapter is `openrouter`. Keeping those names distinct makes it possible to move
a role between connections while leaving Agent definitions unchanged.

Profile settings are defaults. Trusted per-request settings passed to `.ask`
take precedence:

```ruby
run = CustomerSupportAgent.ask(
  "Explain the refund decision.",
  settings: {temperature: 0.0}
)
```

Do not pass unchecked request parameters directly into `settings`. They can
change model cost and behavior and therefore belong to application policy.

## Configure provider connections, not credentials in Agents

LittleGhost includes adapters for OpenRouter, OpenAI-compatible APIs,
Anthropic, Gemini, Vertex AI, and Bedrock. Provider connections may live in the
initializer above or in the conventional files under `config/little_ghost`.
Keep credentials in the application's secret manager and out of Agent classes,
prompts, repositories, logs, and client responses.

Provider connections and model profiles serve different trust boundaries:

- A connection selects an adapter, endpoint, credentials, and other transport
  configuration.
- A profile selects a connection-backed target and trusted model settings.
- A model role is the application-facing name an Agent declares.
- A caller message can influence what the model does, but must not select
  credentials or an unapproved endpoint.

For applications that rotate or obtain credentials at runtime, configure a
trusted credential resolver rather than putting secrets in a profile. Its
return value is merged into the selected provider connection when the model is
constructed. Keep the resolver independent from model-controlled input.

## Choose dynamically only from trusted policy

An Agent may choose a model from its `Invocation`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model do |invocation|
    invocation.fetch(:premium_account, false) ? :premium_support : :customer_support
  end
end
```

Populate `premium_account` from authenticated application state. Do not accept
a raw `provider:model-id` value from a public request unless the application
first maps it through an explicit allowlist. Model selection affects where
prompts, history, attachments, and tool results leave your system.

An inline selection is also supported for trusted code:

```ruby
class ResearchAgent < LittleGhost::Agent
  model(
    provider: "primary",
    model: "openai/gpt-5.6-luna",
    reasoning_effort: "high"
  )
end
```

Here `provider` still names a configured connection. Inline settings do not
create or authorize a new connection.

## Treat model metadata as capability information

`LittleGhost::ModelResolver` resolves a role or target into an executable
`LittleGhost::Model`. Its catalog supplies metadata such as supported input
modalities, output limits, and structured-output capabilities. LittleGhost uses
those facts to reject unsupported attachments, clamp configured output limits,
and select a structured-result strategy.

Remote metadata can become stale or unavailable. Treat it as capability and
routing information, not as an authorization decision or a promise that a
provider will accept every request. Handle failed Runs and provider errors at
the application boundary.

## Review the data path

The selected external provider may receive system and developer instructions,
caller input, conversation history, tool results, structured-output schemas,
and attachments. Before enabling a provider or model, review its retention,
training, data-residency, regional, and logging policies for the data your
application sends.

Use application code for guarantees. A prompt can guide model behavior; it
cannot enforce authorization, spending limits, tenant isolation, or a required
output shape by itself.

Continue with [Structured Outputs and Content](structured_outputs_and_content.md)
to validate result shapes and send images or documents through a selected
model. See [Running in Production](production.md) for configuration precedence,
sessions, lifecycle, and observability.
