# Getting Started

In this guide, you'll run an agent, connect it to a small help center, and stream its answer. The whole feature stays in ordinary Ruby.

## Install the gem

LittleGhost requires Ruby 3.3 or newer. Add the gem to your `Gemfile`, install it, and set a provider credential:

```ruby
gem "little_ghost"
```

```sh
$ bundle install
$ export OPENROUTER_API_KEY="..."
```

Use your application's secret manager outside a local shell, and never commit provider credentials.

## See your first answer

Create `customer_support_agent.rb`:

```ruby
require "little_ghost"

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end

run = CustomerSupportAgent.ask("Can I change the address on my order?")

if run.completed?
  puts run.response
else
  warn "Support request ended as #{run.outcome}: #{run.error&.class}"
end
```

Run the file and you have a working AI feature:

```sh
$ ruby customer_support_agent.rb
```

`CustomerSupportAgent.ask` creates a `LittleGhost::Run` for this request. When the work finishes, the Run holds the outcome and response.

The selected external provider may receive system instructions, caller input, conversation history, tool results, and attachments. Model wording can vary, so use application code—not a prompt—when a rule must always hold.

## Connect the agent to your application

The first agent can answer general questions. A **tool** gives it a focused operation backed by your Ruby code:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  HELP_CENTER_ENTRIES = {
    "refunds" => "Refunds are available within 30 days of purchase.",
    "shipping" => "Standard shipping takes three to five business days."
  }.freeze

  description "Look up a help center entry by topic."
  input_schema(
    type: "object",
    properties: {
      topic: {type: "string", enum: HELP_CENTER_ENTRIES.keys}
    },
    required: ["topic"],
    additionalProperties: false
  )

  def call(input)
    HELP_CENTER_ENTRIES.fetch(input.fetch("topic"))
  end
end
```

Make the tool available to the agent and tell the model when to use it:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt <<~PROMPT
    Answer clearly and do not invent company guidance.
    Check the help center before stating company guidance.
  PROMPT
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask(
  "I bought an item two weeks ago. Can I get a refund?"
)

run.response
# One possible response:
# Refunds are available within 30 days, so your purchase is eligible.
```

LittleGhost checks the model's arguments before it calls `HelpCenterLookupTool#call`. The schema checks shape, not permission. If a tool reads customer data or changes something, authorize that work from trusted application context. The tool's result then becomes context for the model.

## Stream the same agent

Use `.stream_ask` when a console, HTTP response, or user interface should receive progress as it happens:

```ruby
CustomerSupportAgent.stream_ask("Can I get a refund?").each do |event|
  case event.type
  when :text_delta
    print event.data.fetch(:text)
  when :run_error
    warn event.data.fetch(:message)
  end
end
```

The stream yields `LittleGhost::StreamEvent` values. Text, tool activity, usage, and completion all look the same across providers.

## Give the code a home

LittleGhost does not require an application layout. Keep definitions beside related application code, or use these optional conventions:

```text
app/
├── agents/
│   └── customer_support_agent.rb
├── tools/
│   └── help_center_lookup_tool.rb
└── assemblies/
```

You now have the smallest useful LittleGhost application: one Agent, one Tool, and one familiar Ruby call.

When the feature grows, the calling style stays the same. An **assembly** lets one or more agents work as a unit while keeping `.ask` and `.stream_ask`. Read [Core Concepts](core_concepts.md) next and grow this agent into a larger system.
