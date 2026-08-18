# Give agents tools

Tools turn an agent from a writer into a participant in your application. Each
Tool offers one named operation with checked input. Your Ruby code decides what
the operation may do.

Start with a narrow read:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  description "Look up a help center entry by topic."
  input_schema(
    type: "object",
    properties: {topic: {type: "string", enum: %w[refunds shipping]}},
    required: ["topic"],
    additionalProperties: false
  )

  def call(input)
    {
      "refunds" => "Refunds are available within 30 days of purchase.",
      "shipping" => "Standard shipping takes three to five business days."
    }.fetch(input.fetch("topic"))
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end
```

The model sees the Tool's name, description, and input schema. When it chooses
the Tool, LittleGhost checks the arguments, calls `#call`, and returns the
result to the model. That loop can happen several times before the Agent writes
its final answer.

## Keep authority in Ruby

A schema answers “Is this input shaped correctly?” It does not answer “May this
caller perform this operation?” Model-selected arguments remain untrusted after
validation.

Use values established by your application to authorize sensitive work:

```ruby
class OrderStatusTool < LittleGhost::Tool
  description "Look up an order for the current customer."
  input_schema(
    type: "object",
    properties: {order_number: {type: "string"}},
    required: ["order_number"],
    additionalProperties: false
  )

  def call(input)
    Orders.status_for(
      actor_id: run.invocation.actor_id,
      account_id: run.invocation.context.fetch("account_id"),
      order_number: input.fetch("order_number")
    )
  end
end
```

Here, the model chooses `order_number`. The application supplies `actor_id` and
`account_id` after authenticating the request. The Tool reads those trusted
values through its run-scoped binding: the trusted objects LittleGhost attaches
to a Tool for one execution. They are not part of the model's Tool arguments.

The Run also has `context.state`, mutable working state for this execution. When
saved conversations are configured, it may contain values from an earlier Run.
Recheck saved values before using them for authorization.

## Know where a Tool runs

An ordinary Tool is trusted application code. Its `#call` method runs in the
same Ruby process as LittleGhost, with the authority of your application. A
Sandbox does not automatically contain it.

Some Tools deliberately delegate a smaller operation to the Sandbox:

- `LittleGhost::Tools::Filesystem` reads and changes paths through the bound
  Sandbox. It exposes mutation Tools only when that Sandbox is writable.
- `LittleGhost::Tools::Shell` runs one argument vector through the bound
  Sandbox. It does not interpret shell syntax.
- An application Tool can call its bound `sandbox` explicitly for the same
  boundary. Its bound `workspace` provides paths and lifecycle only. Do not pass
  model-selected paths from `Workspace#resolve` to `File`; use Sandbox file
  operations, which reject symlinks while opening the path.

This distinction keeps the architecture predictable:

```text
model ──arguments──> Tool#call ──> application service
                         │
                         └──> bound Sandbox ──> file or process
```

Provider requests also leave from the trusted application process. A Sandbox
network policy applies to processes launched through that Sandbox, not to model
providers, callbacks, or arbitrary Ruby inside a Tool.

Read [Workspaces and Sandboxes](sandboxing.md) before exposing filesystem or
process operations to model influence. It shows how paths, process authority,
networking, and cleanup fit around these delegated Tools.

## Use the run-scoped binding

LittleGhost creates and binds fresh Tool instances for each Agent run. A Run is
one top-level Agent or Assembly execution. A Tool can reach that `run`, its
`agent`, the `runtime` that holds shared configuration and services, and the
current `workspace` and `sandbox` through accessors supplied by
`Tool::Binding`.

That binding carries trusted collaborators, not model arguments. Keep request
identity on `run.invocation`, working state on `context.state`, and the
model-selected input in the `input` passed to `#call`. Keeping those three
sources distinct makes authorization reviews much easier.

Registries close Tool instances that implement `#close`. Tool instance state
therefore belongs to one Agent run unless your Tool deliberately talks to a
shared application service.

## Make concurrency and retries deliberate

LittleGhost may run independent Tool calls concurrently. Mark a Tool
`exclusive true` when it reads or changes shared mutable state that must not
overlap another exclusive Tool in the same run:

```ruby
class UpdateDraftTool < LittleGhost::Tool
  exclusive true
  description "Replace one section of the current account's draft."
  input_schema(
    type: "object",
    properties: {
      section: {type: "string"},
      content: {type: "string"}
    },
    required: %w[section content],
    additionalProperties: false
  )

  def call(input)
    Drafts.replace_section(
      account_id: run.invocation.context.fetch("account_id"),
      section: input.fetch("section"),
      content: input.fetch("content")
    )
  end
end
```

Retries can repeat a Tool call. Prefer read-only operations, idempotency keys,
or writes that are safe to apply more than once. Do not rely on the prompt to
prevent duplicate side effects.

Raise `LittleGhost::ToolError` for an expected failure the model can act on.
Its message is model-visible, so keep it safe to disclose. LittleGhost hides
unexpected exception messages from the model while retaining the original
error for trusted application inspection.

## Let code mode compose the same capabilities

Without code mode, the model chooses one Tool operation and LittleGhost returns
the result before the model chooses the next step. Code mode lets the model
write a small Ruby program that calls several of the same Tools, combines their
results, and returns one useful value.

The authority does not move into that program. Each call crosses back to the
trusted parent process. LittleGhost checks the schema and calls the ordinary
Tool method there, so authorization inside `#call` still applies. Tool limits,
callbacks, events, and tracing also follow the ordinary Tool path.

Continue with [Workspaces and Sandboxes](sandboxing.md) to give delegated file,
process, and interpreter work an enforceable boundary. That guide leads into
code mode once the process model is in place. For exact Tool DSL and result
contracts, see `LittleGhost::Tool` and `LittleGhost::Tool::Binding`.
