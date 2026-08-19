# Code Mode

Code mode lets an Agent combine several Tools in one small program. It is useful
when the model needs to gather independent results, filter them, or make a
bounded decision before returning to its normal conversation loop.

An engine is the adapter that runs the model-authored program. The built-in
engine speaks Ruby and adds no runtime dependency:

```ruby
class SearchTool < LittleGhost::Tool
  tool_name "search"
  description "Search the support knowledge base."
  input_schema(
    type: "object",
    properties: {query: {type: "string"}},
    required: ["query"],
    additionalProperties: false
  )

  def call(input)
    entries = {
      "refund policy" => "Refunds are available within 30 days.",
      "shipping policy" => "Standard shipping takes three to five days."
    }
    entries.fetch(input.fetch("query"), "No matching entry.")
  end
end

LittleGhost.configure do |config|
  config.code_mode = {
    engine: :ruby,
    sandbox: :native
  }
end

class ResearchAgent < LittleGhost::Agent
  tools SearchTool
  code_mode
end
```

The framework adds three control Tools. `exec` starts a program, `wait` checks
on a program that is still working, and `stop` ends a program that is no longer
needed. The model can now call `exec` with Ruby such as:

```ruby
results = tools.parallel(
  -> { tools.search(query: "refund policy") },
  -> { tools.search(query: "shipping policy") }
)

text(results.join("\n"))
```

LittleGhost generates the available method names and keyword arguments from
the Agent's Tool schemas. The model sees this Tool catalog—the list of Tools
available inside the program—in its instructions, so it can use ordinary Ruby
values without guessing each Tool's signature.

## See where code and Tools run

The program runs in a child interpreter. The Tools do not.

```text
model
  │ writes a program
  ▼
exec ──> sandboxed Ruby process
             │ tools.search(...)
             ▼
          Tool broker in the trusted parent
             │ normal Tool execution
             ▼
          SearchTool#call
```

The Tool broker is the component in the trusted parent process that receives
calls from the interpreter. It accepts only Tools registered on the Agent. Each
call then follows the ordinary Tool path: schema validation, Tool execution,
authorization, limits, callbacks, events, and tracing.

Public streams identify brokered calls by their ordinary Tool names and omit
the `exec`, `wait`, and `stop` controls from application Tool activity. Instrumentation—
the callbacks and trace data used to observe work—still records a control
operation around the nested Tool operations. Traces therefore retain the
complete parent-child execution.

Code mode does not make an unsafe Tool safe. An application Tool still runs
with application authority. Filesystem and process access are contained only
when the Tool delegates them through an enforcing Sandbox. Read [Tools](tools.md)
for the Tool boundary and [Workspaces and Sandboxes](sandboxing.md) for the
process boundary before enabling untrusted programs.

## Write one Ruby program

Each `exec` starts a fresh Ruby process. Local variables, constants, and globals
do not carry into a later `exec`. Within one program, the model can use:

- Named methods such as `tools.search(query: "refund policy")`.
- `tools.call(name, arguments)` when the Tool name is dynamic.
- `tools.parallel` for independent calls whose results should preserve input
  order.
- `ALL_TOOLS` to inspect the complete runtime catalog.
- `text(value)` to add user-visible output.
- The program's final expression as the value returned by `exec`.
- `finish(value)` to complete early.

JSON Tool results arrive as ordinary Ruby hashes, arrays, strings, numbers,
booleans, or `nil`. A Tool failure raises inside the program so its Ruby code
can handle the failure or return an error.

Fresh processes keep accidental interpreter state from leaking across programs.
Each Ruby program also owns a temporary Workspace that is removed when the
program ends, so interpreter-local files do not carry into another `exec`. A brokered
filesystem Tool uses the Agent Run's separate Workspace; those files follow
that Workspace's configured lifecycle and may persist.

## Check on work that takes longer

Most programs finish during `exec`, and their result is ready immediately. When
a program takes longer than one minute, `exec` returns `still_working`. The
program continues running. The model can call `wait` to watch it for another
minute or `stop` when its result is no longer useful.

`wait` does not resume, restart, or extend the program. It returns only output
produced since the previous `exec` or `wait`. The returned status tells the
model what to do next:

- `still_working` means the program is active. Call `wait` again when its result
  is still needed, or call `stop` to end it.
- `completed`, `error`, and `terminated` are final. There is no program to wait for
  after one of these statuses.

The built-in engines give each program a total lifetime of one hour by default.
That deadline begins at `exec` and does not reset when the model calls `wait`.
The engine ends and cleans up an expired program even if the model never checks
on it again. Applications can configure a shorter total lifetime with
`wall_seconds`; the one-minute observation window remains fixed.

Only one `exec`, `wait`, or `stop` operation runs for a program at a time. Together, the
engine and active child process form a code-mode session. The Agent closes that
session when the current Agent call ends, including after failure or
cancellation. Cleanup failures raise because LittleGhost cannot claim the child
process and its resources ended cleanly.

## Keep a Tool in the conversation

With code mode enabled, ordinary Agent Tools move into the program catalog. The
model-facing controls become `exec`, `wait`, and `stop`. Use `except` when an
application Tool should remain available to the conversational model instead
of moving into the program:

```ruby
class ResearchAgent < LittleGhost::Agent
  tools SearchTool, ReadResultTool, ConfirmTool
  code_mode except: ["confirm_tool"]
end
```

Exclude a Tool when the conversational model should call it as a distinct
decision—for example, a final confirmation that must remain visible as its own
step. `except` uses each Tool's model-visible name; `ConfirmTool` defaults to
`confirm_tool`. Calls made inside and outside code mode share the Agent's
Tool-call budget. The `exec`, `wait`, and `stop` controls manage execution and do not
consume that application Tool budget themselves.

Managed subagents also stay in the conversation automatically. Their spawn,
messaging, interjection, listing, and waiting controls coordinate model turns;
they are not callable from inside a code-mode program. An asynchronous
subagent continues working after it starts. `wait_for_subagents` checks on that
work for up to 30 seconds and returns either progress or finished results.
This is separate from code-mode `wait`, which watches one interpreter program
for up to one minute.

## Set limits for the work you expect

The Ruby engine supplies bounded defaults for source, output, memory, total wall
and CPU time, files, program submissions (`cells`), Tool calls, concurrency,
and cleanup.
Override only the limits your workload has outgrown:

```ruby
LittleGhost.configure do |config|
  config.code_mode = {
    engine: :ruby,
    sandbox: :native,
    limits: {
      cells: 16,
      wall_seconds: 900,
      cleanup_seconds: 5
    }
  }
end
```

Bubblewrap owns the program's process tree but does not cap its process or thread
count. Use an outer cgroup or container supervisor when untrusted code needs a
hard task-count limit.

Application defaults apply to every Agent that declares `code_mode`. An Agent
can override the engine, Sandbox, limits, or excluded Tools in its own
declaration.

The operating-system Sandbox and the trusted parent process that starts and
cleans up the interpreter form its security boundary. Removing Ruby constants
or methods would not contain native extensions, interpreter bugs, files,
subprocesses, or sockets. Use an enforcing backend for model-authored code and
test the deployed kernel, runtime paths, denied files, child creation,
networking, resource exhaustion, malformed messages from the child process,
cancellation, and cleanup.

## Opt into JavaScript when it fits

The JavaScript engine is optional. It uses MiniRacer and gives each program its own
V8 global state, so the core gem does not require or load MiniRacer:

```ruby
# Gemfile
gem "mini_racer", "~> 0.21"

# application setup
require "little_ghost/code_mode/javascript_engine"

LittleGhost.configure do |config|
  config.code_mode = {engine: :javascript, sandbox: :native}
end
```

The JavaScript program has no Node.js APIs, filesystem, network, console,
WebAssembly, or process-spawning API. Tool methods return Promises, and the
generated instructions include TypeScript declarations derived from each Tool
schema. Use `await` or `Promise.all`, `text(value)` for output, and `exit()` to
complete early. Call `text(value)` first when the value should become
user-visible output.

MiniRacer's language-level restrictions are useful, but the operating-system
Sandbox remains the containment boundary. The Ruby parent still owns the Tool
catalog, authorization, budgets, events, tracing, and resource lifecycle.

## Build a custom engine

Applications can register another `CodeMode::Engine`. It reports its language,
builds the model instructions, and opens a session. A session represents the
engine's ongoing execution state and implements `#execute`, `#wait`, `#stop`,
and `#close`.

The engine receives a function that creates Sandboxes and the Tool broker
described above. It may add named `required_runtime_paths` for interpreter
libraries; those paths are process-only and never become model-visible
filesystem grants. The session owns the Workspace, Sandbox, child process, and
communication resources it creates and closes them in reverse order.

A sandboxed engine must use a backend that owns the complete child process tree
or can enforce a no-child-process policy. An explicitly unrestricted backend
may run an engine, but it does not provide containment.

See `LittleGhost::CodeMode::Engine` and `LittleGhost::CodeMode::Session` for the
extension contracts and their required containment boundary. For
deployment-wide ownership and observability,
continue with [Running in Production](production.md).
