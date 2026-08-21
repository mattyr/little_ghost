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

## Declare one Tool or a collection

An Agent's `tools` declaration accepts one or more classes. Pass a Tool class
directly for one operation:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  tools HelpCenterLookupTool
end
```

Pass several classes in one declaration, or use several declarations. They are
equivalent and inherited declarations are retained:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  tools HelpCenterLookupTool, OrderStatusTool
  tools EscalateConversationTool
end
```

For a related or dynamically discovered collection, pass a provider class that
implements `self.tools(binding)`. It may return Tool classes, Tool instances,
nested arrays, or `nil`; LittleGhost flattens the result and binds every Tool to
the current run:

```ruby
class AccountTools
  def self.tools(binding)
    [
      AccountStatusTool,
      (CloseAccountTool if binding.run.invocation.context["may_close_account"])
    ]
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  tools HelpCenterLookupTool, AccountTools
end
```

Prefer `available_if` on an individual Tool when only that operation is
conditional. Use a provider when the collection itself owns discovery,
construction, or shared setup for an application or remote service.

LittleGhost does not enforce class names. A useful application convention is
to end one model-callable operation with `Tool` and a provider of multiple
operations with `Tools`—for example, `OrderStatusTool` and `AccountTools`.
The suffix makes `tools AccountTools` readable without introducing a framework
base class or hiding ordinary Ruby composition.

## Check permission in Ruby

A schema answers “Is this input shaped correctly?” It does not answer “May this
caller perform this operation?” Use values established by your application to
answer that second question.
For sensitive work, read those values inside the Tool:

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
`account_id` after authenticating the request. The Tool reads those values
through its run-scoped binding: the objects LittleGhost attaches to a Tool for
one execution. They are not part of the model's Tool arguments.

The Run also has `context.state`, mutable working state for this execution. When
saved conversations are configured, it may contain values from an earlier Run.
Recheck saved values before using them for a permission decision.

> **Safety note:** Keep identity and account membership in the Run's invocation,
> not in model-selected arguments. A valid Tool input may still name a record
> the current caller isn't allowed to use.

## Know where a Tool runs

A local Tool is application code. Its `#call` method runs in the same Ruby
process as LittleGhost, with the same access as the rest of your application. A
Sandbox contains only work that the Tool explicitly sends through it.

Some Tools deliberately delegate a smaller operation to the Sandbox:

- `LittleGhost::Tools::Filesystem` reads and changes paths through the bound
  Sandbox. It exposes mutation Tools only when that Sandbox is writable.
- `LittleGhost::Tools::Shell` runs one argument vector through the bound
  Sandbox. It does not interpret shell syntax.
- An application Tool can send work through its bound `sandbox` when it needs
  the same file and process restrictions. Its bound `workspace` names paths but
  does not restrict access to them. Do not pass model-selected paths from
  `Workspace#resolve` to `File`; use Sandbox file operations, which reject
  symlinks while opening the path.

This distinction keeps the architecture predictable:

```text
model ──arguments──> Tool#call ──> application service
                         │
                         └──> bound Sandbox ──> file or child process
```

Provider requests also leave from the application process. Sandbox network
settings apply to processes launched through that Sandbox, not to model
providers, callbacks, or arbitrary Ruby inside a Tool.

Read [Workspaces and Sandboxes](sandboxing.md) before exposing filesystem or
process operations to model influence. It shows which paths and commands a
child process can access, how networking is restricted, and who cleans up the
resources.

## Use the run-scoped binding

LittleGhost creates and binds fresh Tool instances for each Agent run. A Run is
one top-level Agent or Assembly execution. A Tool can reach that `run`, its
`agent`, the `runtime` that holds shared configuration and services, and the
current `workspace` and `sandbox` through accessors supplied by
`Tool::Binding`.

That binding carries application collaborators, not model arguments. Keep request
identity on `run.invocation`, working state on `context.state`, and the
model-selected input in the `input` passed to `#call`. Keeping those three
sources distinct makes permission checks easier to follow.

Registries close Tool instances that implement `#close`. Tool instance state
therefore belongs to one Agent run unless your Tool deliberately talks to a
shared application service.

Use `available_if` when the run itself determines whether an operation exists.
The predicate receives the same binding and runs before the Tool is constructed:

```ruby
class UpdateSlackMessageTool < LittleGhost::Tool
  available_if { |binding| binding.run.invocation.interface == "slack" }
end
```

This controls discovery, not authorization. The Tool must still validate the
caller identity and account permissions supplied by the application.

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

When LittleGhost selects the fiber backend, concurrent Tool calls can run as
fibers on one thread. If a Tool calls a library that blocks that thread, every
other fiber on it must wait too. Suppose the help center lookup later moves to
a client whose `lookup` method is documented to behave this way. Change only
the Tool method:

```ruby
def call(input)
  LittleGhost.offload_blocking do
    HelpCenterClient.lookup(input.fetch("topic"))
  end
end
```

Many Ruby I/O calls already let the scheduler run other fibers. Keep those
calls unchanged. Use `offload_blocking` only when documentation or measurement
shows that the exact call pauses other fibers and the work can continue on
another Ruby thread. Configure the call's own timeout or cancellation when it
provides one.

If most of a Tool's implementation blocks, configure LittleGhost to use the
`:thread` backend instead of wrapping each call. `exclusive true` prevents
overlap with another exclusive Tool; it does not change where the Tool runs.
[Running in Production](production.md#use-an-existing-fiber-scheduler) explains
the concurrency settings and when to adjust the shared thread pool.

Retries can repeat a Tool call. Prefer read-only operations, idempotency keys,
or writes that are safe to apply more than once. Do not rely on the prompt to
prevent duplicate side effects.

Raise `LittleGhost::ToolError` for an expected failure the model can act on.
Its message is model-visible, so keep it safe to disclose. LittleGhost hides
unexpected exception messages from the model while retaining the original
error for trusted application inspection.

## Return values and artifacts

A Tool normally returns one Ruby value. Application callers and code mode
receive that value, while LittleGhost serializes it for the model. Use
`Tool::Result` when the operation also produces files or media:

```ruby
def call(input)
  report = Reports.build(input.fetch("period"))
  LittleGhost::Tool::Result.new(
    value: {rows: report.rows.length},
    artifacts: [
      LittleGhost::Artifact.new(
        data: report.csv,
        media_type: "text/csv",
        name: "report.csv"
      )
    ]
  )
end
```

`Tool::Result#value` is the same plain Ruby value a Tool would otherwise return.
Each inline `Artifact` has bytes, a MIME media type, and an optional name and
metadata. Use `Artifact.deferred(reference:, media_type:, ...)` when another
application service stores the bytes. The optional block passed to
`Configuration#artifacts` receives the deferred Artifact and may use its
application-defined `reference` to load the bytes later.

Artifact handling is opt-in for the Runtime:

```ruby
LittleGhost.configure do |config|
  config.workspace = {
    provider: :directory,
    root: "tmp/agent-runs",
    paths: {artifacts: "artifacts"}
  }
  config.artifacts
end
```

Once enabled, artifact handling covers three cases:

- Input images and documents are stored so filesystem Tools and code mode can
  read the same bytes. The model still receives only the original image or
  document.
- Tool artifacts are stored and returned to the model as images or documents.
  The stored reference is shown only when the media cannot be included in the
  model request.
- Oversized successful Tool values are stored automatically. The model receives
  a short preview and a reference instead of the complete value.

The Tool's Ruby return value does not change. LittleGhost limits the size of
each stored file, the total files and bytes stored for a Run, and the media
sent in one model turn. If an oversized value cannot be stored within those
limits, the application still receives the complete Ruby value and the model
receives a short preview with a storage-limit notice.

To load a deferred artifact, pass a block. It may return bytes, an inline
Artifact with a final MIME type, or `nil` when the referenced file is no longer
available:

```ruby
config.artifacts do |artifact, run:|
  StoredFiles.read(artifact.reference, actor_id: run.invocation.actor_id)
end
```

> **Safety note:** A deferred reference is data, not proof that the current
> caller may read a file. Check it against identity established by the
> application, restrict the storage service or network destination, and limit
> the bytes fetched before returning them. LittleGhost applies its storage limit
> after the resolver returns.

Declaring the named Workspace path does not grant model access. When the Agent
should read artifact references, grant the Sandbox read access to the
`:artifacts` path and include a filesystem Tool. The model can list that path
when a task genuinely needs a stored file; ordinary multimodal work does not
need a second reference to media already in the conversation.

## Let code mode compose the same capabilities

Without code mode, the model chooses one Tool operation and LittleGhost returns
the result before the model chooses the next step. Code mode lets the model
write a small Ruby program that calls several of the same Tools, combines their
results, and returns one useful value.

Each call crosses back to the parent Ruby process. LittleGhost checks the schema
and calls the Tool method there, so permission checks inside `#call` still
apply. Code mode receives the Tool's Ruby return value, while artifacts return
with the surrounding `exec` or `wait` result. Tool limits, callbacks, events,
and tracing work the same way for direct and code-mode calls.

Continue with [Structured Results and Content](structured_outputs_and_content.md)
to give Agent responses a predictable shape and accept images or documents.
For exact Tool DSL and result contracts, see `LittleGhost::Tool` and
`LittleGhost::Tool::Binding`.
