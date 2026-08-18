# Code Mode

Code mode lets a model compose several ordinary Tools in a small program while
the trusted Ruby parent retains every Tool capability. LittleGhost includes a
dependency-free Ruby engine and accepts application-provided engines through
the same interface.

```ruby
LittleGhost.configure do |config|
  config.code_mode = {
    engine: :ruby,
    sandbox: :native,
    limits: {wall_seconds: 10, memory_bytes: 64 * 1024 * 1024}
  }
end

class ResearchAgent < LittleGhost::Agent
  tools SearchTool, ReadResultTool, ConfirmTool
  code_mode direct_tools: ["confirm"]
end
```

The model sees `exec`, `wait`, and each `direct_tools` entry. Other ordinary
Tools appear in the code catalog. The Ruby instructions include deterministic
Ruby-like signatures derived from each Tool's JSON schema. In a cell, code can
use `tools.search(...)`, `tools.call(name, arguments)`, bounded
`tools.parallel`, `ALL_TOOLS`, `text`, `yield_control`, and `finish`.

Every Ruby cell starts a fresh sandboxed Ruby process. Interpreter globals do
not persist between cells. Tool requests cross a framed protocol and are
validated and dispatched by the parent through the ordinary Agent path, so
schema checks, authorization in Tool code, hooks, exclusivity, cancellation,
budgets, events, and tracing still apply. The child cannot grant itself a Tool
or change the catalog.

`yield_control` deliberately pauses a cell until `wait` resumes or terminates
it. A host-side yield interval returns control while the program keeps running;
`wait` continues observing it without sending a protocol resume frame.

## Optional JavaScript engine

The JavaScript engine runs each cell in a fresh MiniRacer-backed V8 context.
MiniRacer remains optional: requiring `little_ghost` does not load it or define
the engine. Add the integration to the application's bundle and load its
entrypoint explicitly:

```ruby
# Gemfile
gem "mini_racer", "~> 0.21"

# application setup
require "little_ghost/code_mode/javascript_engine"

LittleGhost.configure do |config|
  config.code_mode = {engine: :javascript, sandbox: :native}
end
```

The V8 guest has no Node.js APIs, filesystem, network, console, WebAssembly, or
process-spawning API. Tool methods return Promises and the generated
instructions include TypeScript declarations derived from each Tool schema.
The Ruby parent still owns Tool validation, authorization, budgets, hooks,
events, tracing, and sandbox lifecycle.

The operating-system Sandbox and parent supervisor are the security boundary.
Removing Ruby constants or methods would not contain native extensions,
interpreter bugs, filesystem access, processes, or sockets. Configure an
enforcing backend for untrusted cells and test hostile reads, writes, network
access, child creation, infinite loops, memory growth, output flooding, malformed
frames, and cleanup in the deployment environment.

Custom engines implement `CodeMode::Engine#language`, `#instructions`, and
`#open_session`. A session implements `#execute`, `#wait`, and `#close`. Engines
call the supplied sandbox factory with `workspace:` and
`required_runtime_paths:`. The latter maps named Workspace paths to process-only
access required by the engine; it never exposes those paths to Tools. The
factory returns an unopened, session-owned Sandbox, and the session closes the
process, Sandbox, and Workspace in reverse order.

Sandboxed engines require a backend that either owns the complete child process
tree or can enforce a no-child-process policy. An explicitly unrestricted
backend may allow subprocesses, but it does not provide containment. The
built-in native backends satisfy this contract by denying child creation in
isolated macOS sessions and owning the process tree in Bubblewrap sessions.
