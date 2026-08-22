# Choose Models and Providers

An Agent needs a model target: a configured provider connection plus the
provider's model identifier. You can write that target directly while getting
started, then give it an application-facing name when several Agents share it.

## Start with one direct target

A direct target has the form `connection:model-id`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end
```

`openrouter` names a connection configured by the application. The remainder
is the model identifier understood by that provider. This is a good fit when
one Agent owns one stable choice.

## Give shared choices a role

A model role lets several Agents share a choice without knowing its provider
or model identifier:

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

Here `customer_support` is the role, `primary` is the connection, and
`openrouter` is the adapter. You can move the role to another model or provider
without editing the Agent.

Profile settings are defaults. An individual call can override them:

```ruby
run = CustomerSupportAgent.ask(
  "Explain the refund decision.",
  settings: {temperature: 0.0}
)
```

Build these settings in application code instead of passing request parameters
through unchanged. Settings can affect cost, latency, and model behavior.

## Configure connections in one place

LittleGhost includes adapters for OpenRouter, OpenAI-compatible APIs,
Anthropic, Gemini, Vertex AI, and Bedrock. Connections may live in an
initializer or in the conventional files under `config/little_ghost`.

Keep credentials in your application's secret manager. Agents refer to a role
or configured connection; they don't need to contain credentials. If your
application obtains short-lived credentials at runtime, configure a credential
resolver that returns them for the selected connection.

> **Safety note:** The selected provider may receive system instructions,
> caller input, conversation history, Tool results, schemas, and attachments.
> Choose a provider that is appropriate for that data, and keep credentials and
> provider endpoints under application control.

## Choose a role for each request

An Agent can select between configured roles using its `Invocation`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model do |invocation|
    invocation.fetch(:premium_account, false) ? :premium_support : :customer_support
  end
end
```

Set `premium_account` from application state when creating the invocation. If
a public request offers a model choice, map that choice to one of your
configured roles rather than accepting an arbitrary provider target.

Trusted application code may also declare a selection inline:

```ruby
class ResearchAgent < LittleGhost::Agent
  model(
    provider: "primary",
    model: "openai/gpt-5.6-luna",
    reasoning_effort: "high"
  )
end
```

`provider` still names a configured connection. The inline settings change the
selection; they don't create a new connection.

## Use model capabilities

`LittleGhost::ModelResolver` turns a role or target into an executable
`LittleGhost::Model`. Its catalog describes capabilities such as supported
input types, output limits, and structured results. LittleGhost uses that
information to reject unsupported attachments, constrain output limits, and
choose a structured-result strategy.

Provider capabilities can change. Handle failed Runs and provider errors even
when the catalog says a feature is supported.

## Call a model without an Agent

Some application work needs one model response rather than an Agent. Use
`LittleGhost.generate` for tasks such as classification, extraction, or
rewriting when your application already owns the surrounding workflow:

```ruby
response = LittleGhost.generate(
  model: :customer_support,
  messages: [
    {role: :system, content: "Classify the request."},
    {role: :user, content: "My transfer is still pending."}
  ],
  settings: {temperature: 0}
)

response.output
response.usage.total_tokens
```

The operation returns a `LittleGhost::RunResult`, the same result type returned
by an Agent invocation, so
application code can read `output`, `usage`, and the final message in the same
way. Plain generation makes one model request without starting an Agent or
creating a Run. Structured generation may make one additional repair request.

Pass a strict object schema when application code needs checked JSON:

```ruby
response = LittleGhost.generate(
  model: :customer_support,
  messages: [{role: :user, content: "My transfer is still pending."}],
  result_schema: {
    name: "classification",
    description: "Classify one support request",
    schema: {
      type: "object",
      properties: {category: {type: "string"}},
      required: ["category"],
      additionalProperties: false
    }
  }
)

response.output
```

LittleGhost checks the result against the schema and gives the model one repair
attempt. Read the checked value through `response.output`. If both attempts are
invalid, the call raises `LittleGhost::StructuredResultError`.

A schema checks the shape of a value, not whether your application should act
on it. Check identifiers, permissions, and business rules before using the
result to change application state.

## Create embeddings

Use `LittleGhost.embed` when your application needs numeric representations for
search, clustering, or another similarity-based feature:

The example assumes application startup maps `search_embeddings` to an
embedding model, following the role configuration shown earlier on this page.
The selected provider adapter's API reference lists the model-specific
settings.

```ruby
response = LittleGhost.embed(
  model: :search_embeddings,
  inputs: ["Reset a password", "Track a transfer"]
)

response.vectors.length # => 2
response.dimensions
response.usage.input_tokens
```

The response keeps vectors in the same order as the inputs. LittleGhost rejects
an incomplete or malformed response instead of returning a partial batch.
Choose the embedding model and request settings in trusted application
configuration, and keep each call within a workload size your application can
retry safely.

Embedding text is sent to the selected provider. Choose a provider that is
appropriate for that data, just as you would for an Agent request. See
`LittleGhost::Embeddings::Request` and your provider adapter's API reference for
the supported settings and request bounds.

Continue with [Prompts as Views](prompt_views.md) when an Agent's instructions
outgrow one string. See [Structured Results and Content](structured_outputs_and_content.md)
when you need checked result shapes, images, or documents.
