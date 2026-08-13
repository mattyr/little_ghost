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

With `OPENAI_API_KEY` present, LittleGhost can connect the `openai` provider name used below. OpenRouter credentials work as well. Use application secret management outside a local shell, and do not commit provider credentials.

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
  model "openai:gpt-5.6-luna"
  system_prompt <<~PROMPT
    Answer clearly and do not invent company guidance.
    Use the help center lookup tool before stating company guidance.
  PROMPT

  tools HelpCenterLookupTool
end
```

An agent class is a reusable behavior definition. It owns its prompt, tools, model selection, limits, and other capabilities. This agent names an OpenAI connection and model directly, so the first example does not need a separate model profile.

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

## Add a model role when the application grows

Direct targets keep a small application's model choice beside its behavior. A larger application can give the same selection a stable role, then change the underlying provider, model, and defaults without editing each agent class:

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

class CustomerSupportAgent < LittleGhost::Agent
  model :customer_support
end
```

An agent may also keep a small amount of model-specific configuration beside its behavior:

```ruby
class DeliberateSupportAgent < LittleGhost::Agent
  model(
    provider: "openai",
    model: "gpt-5.6-luna",
    reasoning_effort: "high"
  )
end
```

Here, `provider` names a configured connection and every other key after `model` is a trusted model setting. Provider connections and model profiles may instead come from independent YAML files under `config/little_ghost`, or from paths selected in `LittleGhost.configure`. Inline declarations take precedence over explicit paths, which take precedence over conventional files; environment-based selection and the built-in default are the final fallback. `LittleGhost::Agent` and `LittleGhost::Configuration` document the complete shapes and precedence.

## Fit the agent into your application

LittleGhost does not require an application layout. Keep agents and tools beside related application code when your framework or loader already has a home for them. If you want LittleGhost to eager-load definitions, use `app/agents` for agents and `app/tools` for tools.

The agent in this guide owns one model loop. A larger feature may coordinate several participants while preserving the same `ask` and `stream_ask` entrypoints. LittleGhost calls any such callable unit an **assembly**. Workflows, swarms, and graphs are three kinds of coordinated assembly, and they conventionally live in `app/assemblies`. Their class names should state the coordination style, such as `DevelopmentWorkflow`, `ProblemSolverSwarm`, or `SupportFlowGraph`.

Classes are the default way to organize reusable definitions. Core Concepts first explains when to choose each assembly type, then introduces builders for definitions discovered at runtime.

Hosting remains the surrounding application's responsibility. A Rails controller, Rack endpoint, background job, CLI, or another Ruby entrypoint can call the same agent APIs shown above.

Read [Core Concepts](core_concepts.md) next. It begins with the agent you built here, then adds model selection, runs, assemblies, subagents, workflows, swarms, graphs, builders, sessions, and the boundaries between them. The API reference covers exact signatures for `LittleGhost::Agent`, `LittleGhost::Tool`, `LittleGhost::Run`, and the coordination classes.
