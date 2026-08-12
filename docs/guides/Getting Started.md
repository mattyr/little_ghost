# Getting Started with LittleGhost

This guide builds a small AI customer support feature around an agent that checks an in-memory help center and returns a normal Ruby result. By the end, you will have configured a model provider, declared a validated tool, run `CustomerSupportAgent`, and streamed the same request as events.

The example uses OpenAI, but the agent and tool do not depend on that choice. Conventional YAML keeps the provider boundary behind the logical model role `customer_support`.

## Before you begin

LittleGhost requires Ruby 3.3 or newer. Add the gem to your `Gemfile`:

```ruby
gem "little_ghost"
```

Install the bundle and provide the credential used by this example:

```sh
$ bundle install
$ export OPENAI_API_KEY="..."
```

Use application-specific secret management outside a local shell. Do not commit provider credentials.

## Create the application shape

LittleGhost looks for agents, tools, prompts, and skills under conventional application directories. This example needs four files:

```text
customer_support_app/
├── app/
│   ├── agents/
│   │   ├── research_agent.rb
│   │   └── customer_support_agent.rb
│   └── tools/
│       └── help_center_lookup_tool.rb
└── config/little_ghost/
    ├── providers.yml
    └── models.yml
```

Run the application from `customer_support_app/`, or set the configuration root explicitly before the first runtime is built. The runtime loads `config/little_ghost.rb` lazily and eager-loads conventional application code.

## Configure a logical model role

Define the named connection and logical model role in the conventional files:

```yaml
# config/little_ghost/providers.yml
providers:
  openai:
    adapter: openai
    api_key: <%= ENV.fetch("OPENAI_API_KEY") %>

# config/little_ghost/models.yml
default_model: customer_support
models:
  customer_support:
    target: openai:gpt-5
    settings:
      temperature: 0.2
```

The agent will ask for the role `customer_support`; it never needs the provider name or provider model identifier. This separation lets an application change providers or override a profile for one invocation without changing agent classes. Treat model settings and profile overrides as trusted application configuration: construct or allowlist them server-side instead of copying unchecked request fields.

## Give the agent one validated tool

Create `app/tools/help_center_lookup_tool.rb`:

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

A tool exposes a name, description, JSON input schema, and implementation. `HelpCenterLookupTool` gets its default model-visible name from the class name. LittleGhost validates input before calling `#call` and turns the returned value into text for model context.

This boundary is also the right place for application authorization. If lookup behavior or results depended on an account or tenant, `#call` would verify trusted run context before reading them. A schema validates shape; it does not authorize access.

## Define the agents

Create `app/agents/research_agent.rb`:

```ruby
class ResearchAgent < LittleGhost::Agent
  description "Investigates support questions that need broader research."
  model "customer_support.research"
  system_prompt "Research the question and return a concise evidence summary."
end
```

There is no separate `customer_support.research` profile yet. Dotted roles fall back to the nearest registered parent, so this role resolves through `customer_support`. You can add a specialized profile later without changing `ResearchAgent`.

Now create `app/agents/customer_support_agent.rb`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model "customer_support"
  system_prompt <<~PROMPT
    Answer clearly and do not invent company guidance.
    Use the help center lookup tool before stating company guidance.
    Delegate open-ended investigation to the research agent.
  PROMPT

  tools HelpCenterLookupTool
  subagent ResearchAgent, kind: "research"
end
```

The class is a readable behavior boundary. It declares which model role, prompt, tools, and subagent capabilities can participate in a `CustomerSupportAgent` run. Declaring `ResearchAgent` as a subagent gives the model tools for delegation, with the turn, concurrency, and depth limits configured by the surrounding system; it does not force every request through research.

## Run the agent

From the application root, start a Ruby process that requires LittleGhost and asks the agent a question:

```ruby
require "little_ghost"

runtime = LittleGhost::Runtime.new(configuration: LittleGhost.configuration)
customer_support_agent = CustomerSupportAgent.new(runtime:)
run = customer_support_agent.ask(
  "I bought an item two weeks ago. Can I get a refund?"
)

if run.completed?
  puts run.response
else
  warn "Support request ended as #{run.outcome}: #{run.error&.class}"
end
```

`#ask` consumes the invocation and returns its owning `LittleGhost::Run`. A successful run exposes the final text through `#response` and the normalized terminal value through `#result`. It also retains outcome, usage, messages, and any terminal error.

The model can call `HelpCenterLookupTool` with `{"topic":"refunds"}` and answer along these lines:

```text
Refunds are available within 30 days, so a purchase from two weeks ago is eligible.
```

Model wording is not deterministic. The important outcome is that the refund guidance comes from the validated tool result rather than from an unverified guess.

## Stream the response

Use `#stream_ask` when a console, web response, or UI should receive progress before the run completes:

```ruby
CustomerSupportAgent.new(runtime:).stream_ask("Can I get a refund?").each do |event|
  case event.type
  when :text_delta
    print event.data.fetch(:text)
  when :run_error
    warn event.data.fetch(:message)
  end
end
```

The enumerator yields `LittleGhost::StreamEvent` objects. Text, tool activity, usage, traces, subagent activity, and terminal lifecycle facts share that interface, so adapters can translate one framework stream into a console, HTTP stream, or AG-UI transport.

## Where to go next

Read [Core Concepts](Core%20Concepts.md) for the distinction between model-directed subagents and application-directed workflows, how sessions and runs divide ownership, and when `ResponseWorkflow` is a better fit than delegation. The API reference covers exact signatures for `LittleGhost::Agent`, `LittleGhost::Tool`, `LittleGhost::ModelResolver`, and `LittleGhost::Run`.
