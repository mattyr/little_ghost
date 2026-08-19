# Code Mode

Code mode lets an Agent solve a multi-step Tool task in one small program. The
model can gather independent results, filter them, and combine them before it
returns to the conversation. Tool authorization stays in your Ruby application.

Start by adding code mode to an Agent that already has a Tool:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  tool_name "help_center_lookup"
  description "Find a support answer by topic."
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

class ResearchAgent < LittleGhost::Agent
  tools HelpCenterLookupTool
  code_mode
end
```

The language adapter that runs the program is called an engine. By default,
LittleGhost uses its Ruby engine and the native Sandbox for the host operating
system. It fails closed when that Sandbox is unavailable.

Code mode adds three control Tools to the conversation. `exec` starts a
program, `wait` checks on a program that is still working, and `stop` ends work
that is no longer needed. The model can now send Ruby like this to `exec`:

```ruby
results = tools.parallel(
  -> { tools.help_center_lookup(query: "refund policy") },
  -> { tools.help_center_lookup(query: "shipping policy") }
)

text(results.join("\n"))
```

LittleGhost turns the Agent's Tool schemas into Ruby method signatures. The
model sees those signatures and the available Tool names in its instructions.
Those names, descriptions, and signatures form the code-mode Tool catalog. The
model can compose the results with ordinary Ruby values instead of guessing
how to call each Tool.

## See what runs where

The program runs in a child interpreter. The Tools do not.

```text
model
  │ writes a program
  ▼
exec ──> sandboxed Ruby process
             │ tools.help_center_lookup(...)
             ▼
          Tool broker in the trusted parent
             │ normal Tool execution
             ▼
          HelpCenterLookupTool#call
```

The Tool broker receives interpreter calls in the trusted parent process. It
accepts only Tools registered on the Agent, then sends each call through the
same validation, authorization, limits, callbacks, events, and tracing used by
an ordinary Tool call.

Public streams show the brokered Tools by name. They omit the `exec`, `wait`,
and `stop` bookkeeping. Traces still record the control operation around its
nested Tool calls, so you can follow the complete execution.

Code mode does not make an unsafe Tool safe. A Tool still runs with your
application's authority. Filesystem and process access are contained only when
the Tool delegates that work through an enforcing Sandbox. Read
[Tools](tools.md) for the Tool boundary and
[Workspaces and Sandboxes](sandboxing.md) for the process boundary before you
enable untrusted programs.

## Write one Ruby program

Each `exec` starts a fresh Ruby process. Local variables, constants, and globals
do not carry into a later `exec`. Within one program, the model can use:

- Named methods such as `tools.help_center_lookup(query: "refund policy")`.
- `tools.call(name, arguments)` when the Tool name is dynamic.
- `tools.parallel` for independent calls whose results should preserve input
  order.
- `ALL_TOOLS` to inspect the complete runtime catalog.
- `text(value)` to add user-visible output.
- The program's final expression as the completed value returned by `exec` or
  a later `wait`.
- `finish(value)` to complete early.

JSON Tool results arrive as ordinary Ruby hashes, arrays, strings, numbers,
booleans, or `nil`. A Tool failure raises inside the program so its Ruby code
can handle the failure or return an error.

Fresh processes keep interpreter state from leaking across programs. Each Ruby
program also gets a temporary Workspace. LittleGhost removes it when the
program ends, so files created directly by the interpreter do not carry into a
later `exec`.

A brokered filesystem Tool uses the Agent Run's separate Workspace. Files
written through that Tool follow the Run Workspace's configured lifecycle and
may persist.

## Check on work that takes longer

Most programs finish while `exec` is watching them, so their result is ready in
the same Tool call. If a program is still active after one minute, `exec`
returns `still_working`. The program keeps running. The model can call `wait`
to watch for up to another minute or `stop` when it no longer needs the result.

Both `exec` and `wait` return as soon as the program finishes. The one-minute
window is a maximum observation time, not a delay added to every call.

`wait` does not resume, restart, or extend the program. It returns only output
produced since the previous `exec` or `wait`. The returned status tells the
model what to do next:

- `still_working` means the program is active. Call `wait` again when its result
  is still needed, or call `stop` to end it.
- `completed`, `error`, and `terminated` are final. There is no program to wait
  for after one of these statuses.

The built-in engines give each program a total lifetime of one hour by default.
That deadline begins at `exec` and does not reset when the model calls `wait`.
The engine ends and cleans up an expired program even if the model never checks
on it again. Applications can configure a shorter total lifetime with
`wall_seconds`; the one-minute observation window remains fixed.

A code-mode session owns the engine's active child process and related
resources. It accepts only one `exec`, `wait`, or `stop` operation at a time.
The Agent closes the session when its current call ends, including after a
failure or cancellation. Cleanup failures raise because LittleGhost cannot
claim that the child process and its resources ended cleanly.

## Keep a Tool in the conversation

With code mode enabled, ordinary Agent Tools move into the program catalog. The
model-facing controls become `exec`, `wait`, and `stop`. Use `except` when an
application Tool should remain available to the conversational model instead
of moving into the program:

```ruby
class ResearchAgent < LittleGhost::Agent
  tools HelpCenterLookupTool, ConfirmTool
  code_mode except: ["confirm_tool"]
end
```

Exclude a Tool when the conversational model should call it as a distinct
decision—for example, a final confirmation that must remain visible as its own
step. `except` uses each Tool's model-visible name; `ConfirmTool` defaults to
`confirm_tool`. Calls made inside and outside code mode share the Agent's
Tool-call budget. The `exec`, `wait`, and `stop` controls manage execution. They
do not consume that application Tool budget themselves.

Subagent controls also stay in the conversation automatically. A subagent is
another Agent that the parent model can ask for help. The parent can start it,
send it a message, interrupt it, list it, or check on its result. Code-mode
programs cannot call those controls.

An asynchronous subagent keeps working after it starts.
`wait_for_subagents` checks for progress for up to 30 seconds. This is separate
from code-mode `wait`, which watches one interpreter program for up to one
minute.

## Set limits for the work you expect

The Ruby engine sets limits for source and output size, memory, total and CPU
time, file size, the number of programs, Tool calls, concurrency, and cleanup.
Override only the limits your workload needs to change:

```ruby
LittleGhost.configure do |config|
  config.code_mode = {
    engine: :ruby,
    sandbox: :native,
    limits: {
      programs: 16,
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

The operating-system Sandbox contains the interpreter. The trusted parent
starts it, brokers Tool calls, and cleans it up. Language restrictions alone
cannot contain native extensions, interpreter bugs, files, subprocesses, or
sockets.

Use an enforcing Sandbox backend for model-written code. Before production,
test the deployed backend against the files, child processes, networking, and
resource pressure your application expects. Also test cancellation and cleanup
on the deployed host.

## Opt into JavaScript when it fits

The JavaScript engine is optional. It uses MiniRacer and gives each program its
own V8 global state. The core gem does not require or load MiniRacer:

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

Applications can register another `CodeMode::Engine`. An engine names its
language, writes the instructions shown to the model, and opens a
`CodeMode::Session`. The session implements `#execute`, `#wait`, `#stop`, and
`#close`. The first three operations return a `CodeMode::ProgramResult`.

LittleGhost gives the engine a Tool broker and a Sandbox factory. The broker
must stay in the trusted parent process. The factory creates the Sandbox that
contains model-written code. An engine may request named runtime paths for its
interpreter libraries. Those paths are visible to the child process, but they
never become filesystem grants available through Tools.

The session owns every Workspace, Sandbox, child process, thread, and
communication channel it creates. It closes those resources in reverse order.
LittleGhost may use one registered engine instance for concurrent Agent Runs,
so the engine must keep each program's mutable state inside its session.

A sandboxed engine must use a backend that owns the complete child process tree
or can enforce a no-child-process policy. An explicitly unrestricted backend
may run an engine, but it does not provide containment.

See `LittleGhost::CodeMode::Engine`, `LittleGhost::CodeMode::Session`, and
`LittleGhost::CodeMode::ProgramResult` for the extension contract. For
deployment-wide ownership and observability, continue with
[Running in Production](production.md).
