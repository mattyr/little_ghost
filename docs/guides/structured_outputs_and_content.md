# Return Structured Results and Send Rich Content

An Agent can return a checked Ruby value instead of prose. It can also receive
text alongside images and documents when the selected model supports them.

## Declare a result shape

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
checks the supported JSON Schema subset when the Agent is defined and checks
the returned value again before publishing a `LittleGhost::StructuredResult`.

LittleGhost supports a focused subset of [JSON Schema Draft
2020-12](https://json-schema.org/draft/2020-12/json-schema-core). The
`LittleGhost::Agent.result_schema` API reference lists the accepted keywords.

For a structured Agent, `run.result.output` returns the checked value. For an
ordinary Agent, it returns text. Use `run.result.structured_result` when you
also need the schema name.

## Let LittleGhost choose the strategy

The default `strategy: :auto` uses provider-native structured output when it is
available and otherwise uses a terminal Tool when the model supports reliable
Tool calls. You can require one strategy:

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

Use `:provider` or `:tool` when your application depends on that exact path.
LittleGhost raises `LittleGhost::ConfigurationError` before execution if the
selected model cannot provide it.

If the first response is missing or invalid, LittleGhost asks the model to
repair it once. A second invalid response ends the Run with
`LittleGhost::StructuredResultError`.

> **Safety note:** A checked shape tells you that fields and types match the
> schema, not that the model's claims are correct. Apply your normal business
> checks before the result changes data, spends money, or contacts someone.

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
  data: File.binread("tmp/refund-guide.pdf"),
  media_type: "application/pdf",
  name: "refund-guide.pdf"
)
```

`Image` and `Document` hold the original bytes. Serialization base64-encodes
them when they cross a JSON boundary, which increases request size. The
resolved model checks the content type against its advertised input
capabilities before making the provider request.

> **Safety note:** When content comes from an upload, check its size and actual
> file type before creating the block. Send it only to a provider you use for
> that kind of data, and don't treat text extracted from a file as proof of
> identity or permission.

Content blocks may also accompany a Tool result. They become visible to the
model, so apply the same size and disclosure checks as you would for user
content.

Continue with [Compose Agents](assemblies.md) to route a checked result through
several participants, or [Tools](tools.md) when the result should call Ruby
code.
