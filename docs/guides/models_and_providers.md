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

Use one-shot generation for bounded model work that does not need Tools,
Sessions, Workspaces, delegation, or an agent loop:

```ruby
response = LittleGhost.generate(
  model: :customer_support,
  messages: [
    {role: :system, content: "Classify the request."},
    {role: :user, content: "My transfer is still pending."}
  ],
  settings: {temperature: 0}
)

response.output # => one possible classification
response.usage.total_tokens
```

The model selection and settings are trusted application controls, just as
they are for an Agent. The operation returns the same `RunResult` shape as an
Agent invocation, but does not create a Run or invoke agent callbacks.

Pass a strict object schema when application code needs checked JSON:

```ruby
response = LittleGhost.generate(
  model: :classifier,
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

response.output # => {"category" => "transfer_status"}
```

One-shot structured generation requires provider-native structured output. It
checks the returned JSON locally and gives the model one repair attempt before
raising `LittleGhost::StructuredResultError`. JSON schema validates shape, not
authorization or business rules; perform those checks in application code.
As with an Agent result, raw structured JSON is redacted from the returned
message history. Read the validated value through `response.output` or
`response.structured_result.value`.

## Create embeddings

`LittleGhost.embed` returns provider-neutral vectors in input order:

```ruby
response = LittleGhost.embed(
  model: :search_embeddings,
  inputs: ["Reset a password", "Track a transfer"]
)

response.vectors.length # => 2
response.dimensions
response.usage.input_tokens
```

Embedding requests accept at most 128 inputs, 64 KiB per input, and 1 MiB in
aggregate by default. Trusted application code can tighten or raise these
budgets for a bounded operation:

```ruby
LittleGhost.embed(
  model: :search_embeddings,
  inputs: documents,
  limits: {max_inputs: 32, max_input_bytes: 16 * 1024, max_total_bytes: 256 * 1024}
)
```

LittleGhost supports OpenAI embeddings and Amazon Titan Text Embeddings V2 on
Bedrock. OpenAI sends an input batch in one request. Bedrock sends one Titan
request per input, sequentially, so the application controls concurrency and
batch size. A failed batch raises without returning partial vectors.

For Titan V2, configure dimensions and normalization in the model profile:

```ruby
config.models = {
  search_embeddings: {
    target: "aws:amazon.titan-embed-text-v2:0",
    settings: {dimensions: 1024, normalize: true}
  }
}
```

Titan accepts 256, 512, or 1,024 dimensions. OpenAI accepts its model's
supported `dimensions` value. Embedding inputs leave the process for the
selected provider and are excluded from LittleGhost telemetry by default.
Provider responses also have a separate 8 MiB default bound, configurable as
`max_embedding_response_bytes` on the trusted provider connection.

Continue with [Prompts as Views](prompt_views.md) when an Agent's instructions
outgrow one string. See [Structured Results and Content](structured_outputs_and_content.md)
when you need checked result shapes, images, or documents.
