# Workspaces and Sandboxes

A Workspace gives one Run—one top-level Agent or Assembly execution—a stable
set of host paths. A Sandbox decides which operations may reach those paths and
how child processes are contained.

Use them together when an Agent can read files, change files, or run programs:

```ruby
require "fileutils"
require "tmpdir"

LittleGhost.configure do |config|
  config.workspace = lambda do |**|
    root = Dir.mktmpdir("little-ghost-support-")
    LittleGhost::Workspace.new(
      root:,
      teardown: lambda do |workspace:, **|
        FileUtils.remove_entry_secure(workspace.root) if File.exist?(workspace.root)
      end
    )
  end

  config.sandbox = {
    provider: :native,
    files: {root: :read_write},
    root_filesystem: :isolated,
    environment: {inherit: false, set: {"LANG" => "C.UTF-8"}},
    network: :none
  }
end
```

This example gives each Run a temporary writable root and removes it during
teardown. The `:native` Sandbox backend selects Seatbelt on macOS or Bubblewrap on
Linux. It raises instead of running without isolation when the native backend
is unavailable.

`LittleGhost::Tools::Filesystem` and `LittleGhost::Tools::Shell` use the Sandbox
assigned to the current Run. Code-mode interpreters also run inside their own
Sandbox. Ordinary application Tools, callbacks, and provider requests stay in
the Ruby process unless they deliberately delegate an operation.

The split looks like this:

```text
Ruby application process
├── provider requests
├── application Tool#call
└── Sandbox
    ├── bounded filesystem operations
    ├── Shell child processes
    └── code-mode interpreter processes
```

## Give files a stable home

A Workspace names the files available during a Run and controls their setup and
cleanup. Its `root` is the default working directory. Named paths give important
directories logical identities:

```ruby
workspace = LittleGhost::Workspace.new(
  root: "/var/lib/support/run-481",
  paths: {
    source: "/srv/support/source",
    skills: "skills",
    home: "runtime-home"
  }
)
```

Relative named paths live beneath the root and are created when the Workspace
opens. Absolute named paths are references deliberately supplied by the
application and must already exist. A setup callback can provision them when
needed.

Opening resolves real paths and records which physical directories they refer
to. LittleGhost rejects two names that point to the same directory and later
fails closed if a configured directory is replaced. Nested paths are allowed,
and the most restrictive matching access wins.

Workspace object lifetime and file lifetime are separate. Closing invokes the
configured teardown callback, but does not delete files by default. Use a
run-scoped temporary root for disposable work. Use application-managed storage,
tenant isolation, and concurrency control when several Runs share files.

## Give artifacts logical references

Images and documents normally remain provider content. When filesystem Tools
or code mode should read the same bytes, configure the conventional artifact
path and enable artifact handling:

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

LittleGhost stores input images and documents after the Workspace and Sandbox
open. The model receives the image or document in its normal input without a
second text reference. Filesystem Tools can list `workspace://artifacts` when a
later operation needs the stored copy. Messages added while the Run is active
receive the same treatment.

LittleGhost limits the number and size of files stored from each message and
across the complete Run. Those limits also include Tool artifacts and oversized
Tool results. A successful operation stores all of its files. If storage fails
partway through, LittleGhost attempts to remove that operation's files and
reports a cleanup error when it cannot. Stored files use private permissions,
and the Workspace provider still owns final cleanup.

Declaring the path does not grant model access. When the Agent should read it,
grant the Sandbox access to `:artifacts` and include a filesystem Tool.

## Pass logical paths, not host layout

The Filesystem Tool accepts root-relative paths such as `notes/today.md`.
Named paths use references such as
`workspace://skills/refunds/SKILL.md`.

Those references remain meaningful without exposing or translating the host
layout. The Filesystem Tool rejects physical absolute paths. Child processes
use the Workspace's real paths directly, start in its root, and receive
`LITTLE_GHOST_WORKSPACE_ROOT` plus one
`LITTLE_GHOST_WORKSPACE_<NAME>` variable for each named path.

Workspace references give application code one stable path format. Each
Sandbox backend applies the configured access using the filesystem controls
available on its host.

## Separate Tool-visible files from process support

Sandbox configuration divides named paths into two groups:

```ruby
config.sandbox = {
  provider: :native,
  files: {
    root: :read_write,
    source: :read_only,
    skills: :read_only
  },
  runtime_paths: {
    home: :read_write
  },
  network: :none
}
```

`files` are visible to both the Filesystem Tool and sandboxed processes.
`runtime_paths` are process-only. Use runtime paths for interpreter libraries,
homes, sockets, and service state that a model should not browse through a
filesystem Tool.

This is visibility, not secrecy from the process. A child with a runtime-path
grant can use that path according to its access mode. The distinction prevents
the Filesystem Tool from offering it as a model-visible file
tree.

## Narrow access with a Scope

A `Sandbox::Scope` is a non-owning, reduced view of a Sandbox. It can remove
paths, change writable access to read-only, remove capabilities (categories of
allowed operations), or narrow networking. It cannot widen its parent:

```ruby
reviewer = run.sandbox.scope(
  files: {source: :read_only},
  runtime_paths: [],
  capabilities: %i[filesystem_read filesystem_list],
  network: false
)
```

Scopes constrain only code that receives and uses the Scope. Code that keeps a
reference to the parent Sandbox keeps the parent's authority. A Scope does not
open or close its parent and owns no resources.

## Choose how much of the host exists

`root_filesystem` controls what a sandboxed process can see beyond declared
Workspace paths:

- `:isolated` exposes only declared paths and required runtime support. It is
  the default and the right starting point for generated interpreters.
- `:read_only` exposes the host filesystem for development commands while
  confining writes to declared writable paths. It makes installed compilers,
  package managers, profiles, and toolchains available, but the child can also
  read host files unless the Ruby process already runs inside a container or VM
  that prevents those reads.
- `:read_write` grants the host filesystem directly. Treat it as unrestricted
  host authority.

On Seatbelt, host-visible modes permit subprocesses because development tools
often need them. A Scope can remove `process_spawn` for a command that does not.

## Choose an enforcement backend

| Sandbox backend | Host | What it enforces |
| --- | --- | --- |
| `:native` | macOS or Linux | Selects Seatbelt on macOS and Bubblewrap on Linux; fails closed elsewhere |
| `:seatbelt` | macOS | Deny-default Seatbelt profile over the configured physical paths |
| `:bubblewrap` | Linux | Fresh user, PID, mount, IPC, UTS, and optional network namespaces |
| `:unrestricted` | Ruby platforms | No containment; commands have the application process's host authority |

`LittleGhost::Sandbox.probe(:native)` reports whether the platform backend is
available. Selecting an enforcing backend never falls back to unrestricted
execution.

Bubblewrap owns descendants with a PID namespace and ends them when the
supervising process dies. It cannot selectively deny fork inside that
namespace, so a request for
`allow_subprocesses: false` fails closed rather than claiming an unenforced
restriction. Bubblewrap does not impose a task-count limit by itself. Use an
outer cgroup or container supervisor when generated code needs a hard cap on
the processes and threads it can create.

Seatbelt can constrain spawned children, but macOS has no PID namespace. It
terminates the command process group during cleanup; a child that deliberately
detaches from that group may survive. Use an outer process or container
supervisor when complete descendant ownership is required on macOS.

> **Safety note:** `LittleGhost::Sandboxes::Unrestricted` is suitable for
> application commands and tests that you would already run directly. It
> validates paths and bounds output, but it does not isolate the command from
> the host. Use `:native` for generated commands in production.

## Keep process ownership explicit

`Sandbox#start_program` returns a `Sandbox::ProcessSession` with bounded input
and output, `alive?`, bounded `wait(timeout:)`, `terminate`, and `close`. The
session starts the command in a process group so cleanup can stop it and its
ordinary descendants together. It applies available CPU, memory, file, and
output limits, requests termination, and then forces termination when needed.

Callers that open a ProcessSession own it and must close it. LittleGhost fails
closed when it cannot supervise a configured memory limit. The parent samples
the visible process tree every 100 milliseconds, so it reacts only to memory
present at a sample and may miss peaks between samples. On Linux, three
consecutive failures to read the root process or the `/proc` snapshot end the
process. Use an outer cgroup or container when memory must be enforced as a hard
limit by the operating system.

A Run closes the Workspace and Sandbox it creates after success, failure, a
partial response, or cancellation. Application-supplied instances remain
caller-owned.

## Configure child-process networking separately

Sandbox networking has three modes:

- `:none` removes child networking.
- `:inherit` permits the selected Sandbox backend's ordinary network access.
- `:allowlist` requires an enforcing gateway: a supervised proxy that permits
  only configured destinations.

Proxy environment variables alone are not an allowlist. An external gateway
uses named, process-only Workspace paths and verifies that they still point to
the configured directories; it does not create a virtual path mapping.
LittleGhost does not attest that an external proxy is ready or enforcing the
declared destinations. The application must supervise and verify that
gateway before giving a child network access.

These settings reach only processes launched through the Sandbox. Providers,
callbacks, and application Tool code still use the Ruby process's network
access.

Test the deployed kernel and filesystem, not only the configuration object.
Exercise denied reads and writes, runtime paths, child creation, direct sockets,
cancellation, limits, and cleanup before depending on the Sandbox to isolate
generated code.

Continue with [Code Mode](code_mode.md) to see how a model-authored interpreter
uses this setup while every Tool call stays in the parent Ruby process. For
exact setup, access, and cleanup behavior, see `LittleGhost::Workspace`,
`LittleGhost::Sandbox`, and `LittleGhost::Sandbox::Scope`.
