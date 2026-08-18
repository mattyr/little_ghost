# Workspaces and Sandboxes

A Workspace names the physical directories a Run owns. A Sandbox decides which
of those directories brokered filesystem tools and child processes may reach.
There are no virtual mount targets: macOS Seatbelt and Linux Bubblewrap both use
the Workspace's existing paths.

## Declare paths once

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

`Workspace#open` creates the root and relative named paths. Absolute named
paths are trusted references and must already exist; a setup callback can
provision them deliberately. Opening records every directory's real path and
filesystem identity, rejects duplicate physical aliases, and fails later
operations if a configured directory is replaced. Nested paths are valid; the
most restrictive matching access applies.

Brokered tools accept relative root paths such as `notes/today.md` and named
references such as `workspace://skills/refunds/SKILL.md`. They reject physical
absolute paths and return logical references, so prompts need not know the host
layout. Child processes start in the Workspace root and receive
`LITTLE_GHOST_WORKSPACE_ROOT` plus `LITTLE_GHOST_WORKSPACE_<NAME>` variables.

## Separate files from runtime paths

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
  root_filesystem: :read_only,
  environment: {inherit: false, set: {"LANG" => "C.UTF-8"}},
  network: :none
}
```

`files` are visible to brokered filesystem tools and sandboxed processes.
`runtime_paths` are process-only; they are useful for interpreter homes,
sockets, and service state that a model should not browse directly. A Scope can
remove or make paths read-only, but cannot promote a runtime path into a file
grant or widen its parent:

```ruby
reviewer = run.sandbox.scope(
  files: {source: :read_only},
  runtime_paths: [],
  capabilities: %i[filesystem_read filesystem_list],
  network: false
)
```

`root_filesystem: :isolated` exposes only the declared Workspace and required
runtime paths. It is the default and is appropriate for untrusted interpreters.
`root_filesystem: :read_only` additionally exposes the host filesystem for
development commands while keeping writes confined to declared writable paths.
This makes installed compilers, package managers, system profiles, and selected
developer toolchains available without maintaining a platform-path allowlist,
but it also lets the child read host files unless the hosting boundary protects
them separately. On Seatbelt, these explicitly host-visible modes also permit
subprocesses; a scope can remove `process_spawn` when a command does not need
children. `:read_write` grants the host filesystem directly and should be
treated as unrestricted host authority.

## Choose an enforcement backend

| Provider | Host | Boundary |
| --- | --- | --- |
| `:native` | macOS or Linux | Selects Seatbelt on macOS and Bubblewrap on Linux; fails closed elsewhere |
| `:seatbelt` | macOS | Deny-default Seatbelt profile over identity paths |
| `:bubblewrap` | Linux | Fresh user, PID, mount, IPC, UTS, and optional network namespaces |
| `:unrestricted` | Ruby platforms | No containment; commands have the application process's host authority |

`LittleGhost::Sandbox.probe(:native)` reports whether the platform backend is
available. An explicit isolated backend never falls back to unrestricted
execution. Seatbelt cannot bind or rename paths, which is why Workspace names
are logical references instead of a second filesystem topology. Bubblewrap
uses identity binds internally to provide the same contract. Seatbelt lets
development commands spawn children, and those children inherit its filesystem
and network restrictions. macOS has no PID namespace, so cleanup of a child
that deliberately detaches from the command's process group is best effort.
Bubblewrap's PID namespace and parent-death controls own descendants for the
full sandbox lifecycle. It cannot selectively deny fork inside that namespace,
so `allow_subprocesses: false` fails closed instead of claiming to enforce a
restriction it cannot provide.

The unrestricted provider remains convenient for trusted application commands,
but path checks and output bounds do not make it a security boundary.

## Own interactive processes

`Sandbox#start_program` returns a `Sandbox::ProcessSession` with bounded duplex
I/O, `alive?`, bounded `wait(timeout:)`, `terminate`, and `close`. The session
starts a process group with a scrubbed environment, supervises memory from the
trusted parent, applies available CPU, file, and process limits, and terminates
the owned process group with TERM followed by KILL. Bubblewrap adds PID-namespace
ownership for descendants. Seatbelt terminates the command process group, but
cannot guarantee cleanup of deliberately detached descendants. A missing memory
supervisor fails closed. Callers that open a session own it and must close it.

## Keep networking separate

`:none` removes child networking, `:inherit` permits ordinary backend network
access, and `:allowlist` requires an enforcing gateway. Environment proxy
variables alone are not an allowlist. An external gateway uses named
process-only Workspace paths and physical identity checks; it does not create a
bind mapping.

Sandbox policy applies to processes launched through the Sandbox. Provider
requests, callbacks, and custom Ruby Tools still run in the trusted application
process. Test the final deployed kernel, runtime roots, denied files, child
creation, direct sockets, cancellation, limits, and cleanup before treating the
configuration as an enforcement boundary.

## Migrate from mounts and Docker

The named-path policy replaces the former `workspace_path`, `workspace_access`,
`mounts`, and `execution_scope` options. Move every host directory into
`Workspace#paths`, then grant its name under `files` or `runtime_paths`. Child
processes now see the same physical paths as the application; use
`workspace://name/...` references when passing paths through model-visible
filesystem tools.

The Docker provider is no longer included. Select `:native` for Seatbelt on
macOS and Bubblewrap on Linux, or configure an application-owned custom Sandbox
when deployment requires a container boundary. Unsupported legacy policy keys
and the `:docker` provider fail explicitly instead of silently changing the
isolation boundary.
