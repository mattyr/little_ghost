# Getting Started with LittleGhost

This guide builds a customer support agent that checks a small help center before answering. It focuses on the Ruby objects needed for one useful run: a tool, an agent, and the call that starts it.

LittleGhost runs inside your Ruby process. It does not choose how your application is hosted or where these definitions live.

## Install LittleGhost

LittleGhost requires Ruby 3.3 or newer. Add the gem to your `Gemfile`:

```ruby
gem "little_ghost"
```

Install the bundle and set a provider credential:

```sh
$ bundle install
$ export OPENAI_API_KEY="..."
```

With `OPENAI_API_KEY` present, LittleGhost's default model role uses GPT-5.6 Luna through OpenAI. OpenRouter credentials work as well. Use application secret management outside a local shell, and do not commit provider credentials.

## Give the agent a tool

Start by requiring LittleGhost and defining a narrow help center lookup:

```ruby
require "little_ghost"

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

A tool gives the model one application operation with a name, description, and validated JSON input. LittleGhost validates the input before calling `#call` and turns the returned value into model context.

The schema checks shape, not authorization. A tool that reads customer data or performs an action must enforce the application's trust rules inside its implementation.

## Define the agent

Now describe the agent's behavior and make the lookup available to it:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  system_prompt <<~PROMPT
    Answer clearly and do not invent company guidance.
    Use the help center lookup tool before stating company guidance.
  PROMPT

  tools HelpCenterLookupTool
end
```

An agent class is a reusable behavior definition. It owns its prompt, tools, model role, limits, and other capabilities. This agent uses LittleGhost's `default` model role because it does not declare a different one.

## Ask a question

Call the agent class to run one request to completion:

```ruby
run = CustomerSupportAgent.ask(
  "I bought an item two weeks ago. Can I get a refund?"
)

if run.completed?
  puts run.response
else
  warn "Support request ended as #{run.outcome}: #{run.error&.class}"
end
```

`CustomerSupportAgent.ask` creates and consumes a `LittleGhost::Run`. A successful run exposes its final text through `#response`; it also retains the normalized result, outcome, usage, messages, and any terminal error.

The model can call `HelpCenterLookupTool` with `{"topic":"refunds"}` and answer along these lines:

```text
Refunds are available within 30 days, so a purchase from two weeks ago is eligible.
```

Model wording and tool selection are not deterministic. The prompt directs the agent to ground company guidance in the validated lookup; applications that must enforce a lookup should put that ordering in a workflow.

## Stream the same agent

Use `.stream_ask` when a console, HTTP response, or user interface should receive progress while the run is active:

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

The stream yields `LittleGhost::StreamEvent` objects. Text, tool activity, usage, traces, and terminal lifecycle facts share this interface, so callers do not need provider-specific response handling.

Both calls use the same agent definition and active LittleGhost configuration. Core Concepts explains reusable runtimes when an application needs more control over shared services.

## Choose a provider or model explicitly

The defaults keep the first run short. Applications that want a named model role can configure one directly:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
  }
  config.models = {
    customer_support: {
      target: "openai:gpt-5.6-luna",
      settings: {temperature: 0.2}
    }
  }
  config.default_model = :customer_support
end
```

Provider connections and model profiles may instead come from independent YAML files under `config/little_ghost`, or from paths selected in `LittleGhost.configure`. Inline declarations take precedence over explicit paths, which take precedence over conventional files; environment-based selection and the built-in default are the final fallback. `LittleGhost::Configuration` documents the complete shapes and precedence.

## Fit LittleGhost into your application

LittleGhost does not require an application layout. Keep agents and tools beside related application code when your framework or loader already has a home for them. If you want LittleGhost to eager-load these definitions, `app/agents` and `app/tools` are available conventions, and every lookup path is configurable.

Hosting remains the surrounding application's responsibility. A Rails controller, Rack endpoint, background job, CLI, or another Ruby entrypoint can call the same agent APIs shown above.

Read [Core Concepts](core_concepts.md) next for model roles, reusable runtimes, subagents, workflows, sessions, and the boundaries between them. The API reference covers exact signatures for `LittleGhost::Agent`, `LittleGhost::Tool`, `LittleGhost::Configuration`, and `LittleGhost::Run`.
