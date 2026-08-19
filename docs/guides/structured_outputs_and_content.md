# Return Structured Results and Send Rich Content

An Agent can return a locally validated JSON-shaped value instead of relying on
application code to parse prose. Messages can also combine text with images and
documents when the selected model advertises those input modalities.

## Declare a strict result contract

Use `result_schema` on the Agent:

```ruby
class SupportTriageAgent < LittleGhost::Agent
  model :customer_support
  system_prompt "Classify the request using only the supplied evidence."

  result_schema(
    name: "support_triage",
    description: "Routing decision for one support request",
    type: "object",
    properties: {
      category: {
        type: "string",
        enum: %w[billing delivery returns other]
      },
      urgent: {type: "boolean"},
      summary: {type: "string", maxLength: 500}
    },
    required: %w[category urgent summary],
    additionalProperties: false
  )
end

run = SupportTriageAgent.ask("My package is missing and I leave tomorrow.")

if run.completed?
  triage = run.result.output
  route_request(category: triage.fetch("category"), urgent: triage.fetch("urgent"))
else
  report_failure(run.error)
end
```

Every object in a result schema must set `additionalProperties: false` and list
every property in `required`. The top-level type must be `object`. LittleGhost
checks the supported JSON Schema subset when the Agent class is defined and
validates the returned value locally before publishing it as a
`LittleGhost::StructuredResult`.

LittleGhost intentionally supports a constrained subset of [JSON Schema Draft
2020-12](https://json-schema.org/draft/2020-12/json-schema-core). Check
`LittleGhost::Agent.result_schema` for the accepted keywords rather than
assuming that every JSON Schema feature is available.

`run.result.output` returns the validated value for a structured Agent and text
for an ordinary Agent. Use `run.result.structured_result` when the schema name
also matters.

## Let capabilities choose the transport

The default `strategy: :auto` prefers provider-native structured output and
uses a terminal Tool when the model supports reliable tool calls instead. You
may require one strategy:

```ruby
result_schema(
  {
    type: "object",
    properties: {answer: {type: "string"}},
    required: ["answer"],
    additionalProperties: false
  },
  name: "answer",
  strategy: :provider
)
```

Use `:provider` or `:tool` only when deployment policy requires it. LittleGhost
raises `LittleGhost::ConfigurationError` before execution if the selected model
cannot provide the required strategy.

An absent or invalid result receives one repair attempt. During a repair turn,
ordinary Tools cannot run. If the second result remains invalid, the Run fails
with `LittleGhost::StructuredResultError`. A checked shape does not make the
values true: continue to apply application validation and authorization before
using them for side effects.

Structured payloads are redacted from retained conversation messages and
ordinary telemetry paths. The validated value still exists in the returned
Run, so protect that object and any application logging around it.

## Combine text with an image

Build a user `Message` from typed content blocks:

```ruby
image = LittleGhost::Content::Image.new(
  data: File.binread("tmp/damaged-package.png"),
  media_type: "image/png"
)

message = LittleGhost::Message.new(
  role: :user,
  content: [
    LittleGhost::Content::Text.new(
      text: "Describe the visible damage without guessing its cause."
    ),
    image
  ]
)

run = DamageReviewAgent.ask(message)
```

For a document, include a display name:

```ruby
document = LittleGhost::Content::Document.new(
  data: File.binread("tmp/refund-policy.pdf"),
  media_type: "application/pdf",
  name: "refund-policy.pdf"
)
```

`Image` and `Document` hold the original bytes. Serialization base64-encodes
them when they cross a JSON boundary. This can substantially increase request
size; enforce upload size, file type, decompression, and malware policies before
constructing the block.

## Check capability and data boundaries

The resolved model validates an attachment against its advertised input
modalities. An image requires image support; a PDF document requires PDF
support; other documents require file support. Unsupported input raises before
the provider request. Provider-specific file limits and supported MIME types may
be narrower, so validate those at the upload boundary too.

An attachment may contain personal data, secrets, hidden text, active content,
or adversarial instructions. Treat its content as untrusted model input. Do not
use a filename, media type, or model description as proof of what the bytes
contain. Send it only to a provider approved to receive that data, and do not
grant Tools authority based on claims extracted from it.

Content blocks can also appear in Tool companion content. An ordinary Tool
still runs with application authority, while the returned image or document is
model-visible. Apply the same disclosure and size rules to Tool results.

Continue with [Tools](tools.md) when a structured decision should call
application code, and [Choose Models and Providers](models_and_providers.md)
when a modality or structured-output strategy must influence routing.
