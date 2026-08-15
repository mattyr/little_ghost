# Workspaces, Sandboxes, and Tools

LittleGhost can give model-directed work a bounded filesystem and process view,
but “sandboxed” is not one blanket guarantee. The result depends on which code
uses the Sandbox, which backend enforces its policy, what the outer runtime
allows, and whether networking has a path around the configured gateway.

This guide helps you choose those boundaries deliberately. It begins with the
objects involved, then follows one command from trusted Ruby code into an
isolated child process.

## Start with an explicit boundary

Without configuration, each Run receives a Workspace rooted at the configured
application root and `LittleGhost::Sandboxes::Unrestricted`. That default has no
external dependency, but it is not process or network isolation. A command can
act with the Ruby process's host permissions.

**Warning:** Use the unrestricted backend only when commands and paths are
trusted. Path checks, read-only scopes, and output limits are useful application
guardrails, but a host command can bypass them.

Choose an enforcing backend when a model can influence commands. Docker is the
built-in choice that can be used from both macOS and Linux hosts:

```ruby
require "fileutils"
require "securerandom"

LittleGhost.configure do |config|
  config.workspace = lambda do |**|
    root = File.join(
      "/var/lib/customer_support/runs",
      SecureRandom.uuid
    )

    LittleGhost::Workspace.new(
      root:,
      setup: ->(workspace:, **) { FileUtils.mkdir_p(workspace.root) },
      teardown: lambda do |workspace:, **|
        if File.exist?(workspace.root)
          FileUtils.remove_entry_secure(workspace.root)
        end
      end
    )
  end
  config.sandbox = {
    provider: :docker,
    image: "customer-support-runtime@sha256:...",
    workspace_path: "/workspace",
    workspace_access: :read_write,
    root_filesystem: :read_only,
    environment: {inherit: false, set: {"LANG" => "C.UTF-8"}},
    network: :none,
    execution_scope: :command
  }
end
```

LittleGhost does not install Docker, Bubblewrap, Socat, or Envoy. Selecting a
backend or gateway makes that dependency part of your deployment. An unavailable
dependency raises an error instead of falling back to unrestricted execution.

## Give each object one responsibility

A **Workspace** names the host paths associated with a Run. It does not isolate
those paths, create them, delete them, or make them private by itself.

A **Sandbox** maps Workspace paths and additional mounts into a virtual
filesystem, exposes bounded filesystem operations, and launches child processes
under a backend's policy.

A **Scope** is a non-owning, capability-reduced view of a Sandbox. It can remove
mounts or operations, narrow a mount to a descendant, change writable access to
read-only, or change inherited or allowlisted networking to no networking. It
cannot widen its parent.

A **Tool** is Ruby application code. Built-in filesystem and shell tools use the
Sandbox in their binding. A custom Tool runs in the trusted Ruby process unless
it deliberately calls its bound `sandbox` or a selected `sandbox.scope`.

A **Run** connects these objects. When the Runtime creates them, the Run opens
the Workspace before the Sandbox and closes them in reverse order. Passing an
existing Workspace or Sandbox keeps lifecycle ownership with your application.

```text
host, VM, or outer container
└── trusted Ruby runtime
    ├── model providers, custom Ruby tools, callbacks, and credentials
    └── Run
        ├── Workspace: host paths and application lifecycle
        └── Sandbox / Scope
            ├── bounded filesystem broker
            └── child process
                ├── namespace or container policy
                └── none, inherited network, or enforced gateway
```

The diagram is a trust map, not a security rating. Each lower layer still relies
on the layers above it.

## Understand the enforcement layers

| Layer | What it controls | What it does not control |
| --- | --- | --- |
| Hosting platform | The outer process, container or VM, kernel, IAM, secrets, inbound access, and service network | Application authorization and the mounts selected for a child |
| Trusted Ruby runtime | Provider calls, custom Tools, callbacks, policy construction, and credentials | Model-controlled native code after it enters an enforcing backend |
| Workspace | Which host paths belong to the Run's configuration and when application callbacks run | Filesystem isolation, uniqueness, deletion, or concurrency |
| Scope and tool binding | Which Sandbox operations a Tool receives | Code that retains the parent Sandbox or performs work directly in Ruby |
| Sandbox backend | The filesystem, process, environment, and child-network policy it implements | The outer kernel or daemon, provider calls, arbitrary Ruby code, or hosting IAM |
| Egress gateway | Destinations, and optionally HTTP request metadata, for traffic forced through it | Direct sockets that the Sandbox did not block |
| Model provider | The provider's own processing and retention boundary | Data already exposed by Tools or included in model requests |

Defense in depth comes from composing these layers. A containerized application
with a nested process sandbox still trusts its outer container configuration,
the shared kernel or VM, its application code, and every deliberately exposed
mount and service.

## Choose a backend for the deployment

| Provider | Host support | Process boundary | Lifecycle | Important trust |
| --- | --- | --- | --- | --- |
| `:unrestricted` | Ruby platforms | None; commands run on the host | One Run-owned object | The Ruby process, command, and host filesystem |
| `:bubblewrap` | Linux | Fresh user, PID, mount, IPC, and UTS namespaces for each command; network namespace when networking is not inherited | Command-scoped | The outer Linux kernel, Bubblewrap installation, runtime roots, mounts, and command wrapper |
| `:docker` | Linux or a macOS Docker environment | Linux container with explicit bind mounts and network | Fresh container per command or one container per Sandbox | The Docker daemon, selected image, outer host or VM, bind mounts, and daemon configuration |

Bubblewrap shares the outer Linux kernel. Running it inside another container
adds a layer, but does not remove that shared-kernel dependency. Namespace
creation must be permitted in the deployed environment, so probe and smoke-test
the final runtime image rather than assuming that a successful build proves
runtime availability.

Docker access is itself privileged. Do not mount the Docker socket into a
model-controlled container. Pin and review the image that becomes the sandbox
root filesystem. On macOS, the Docker daemon normally runs Linux containers in
a VM; LittleGhost still interacts with it through the Docker command-line
interface.

`LittleGhost::Sandbox.probe(:bubblewrap)` and
`LittleGhost::Sandbox.probe(:docker)` report whether a backend can start in the
current environment. A successful probe is a dependency check, not a security
certification or a substitute for an end-to-end policy test.

## Decide what the Workspace owns

Workspace object lifetime and file lifetime are separate decisions. The default
Workspace has no setup or teardown behavior. Closing it does not remove its
root.

Use a callable declaration when paths depend on the Run or need lifecycle
callbacks:

```ruby
config.workspace = lambda do |**|
  root = File.join("/var/lib/customer_support/runs", SecureRandom.uuid)

  LittleGhost::Workspace.new(
    root:,
    paths: {attachments: "attachments"},
    setup: lambda do |workspace:, **|
      FileUtils.mkdir_p(workspace.path(:attachments))
    end,
    teardown: lambda do |workspace:, **|
      FileUtils.remove_entry_secure(workspace.root)
    end
  )
end
```

Relative named paths must remain beneath the Workspace root. An absolute named
path is a deliberate reference outside that root and should come only from
trusted application configuration.

If several Runs use the same writable root, the application must serialize
their access or make the storage safe for concurrent tenants. A per-Run
Workspace object does not make a shared directory per-Run. Teardown should also
account for partial setup: Workspace calls it after a setup failure when setup
has begun.

When Sandbox policy depends on paths created during `Workspace#open`, the
Bubblewrap `setup:` callback runs afterward and returns `policy:` plus optional
`profiles:`. Keep provisioning in the Workspace callback and keep filesystem,
process, and network declarations in Sandbox policy.

## Map files for processes and tools

The Workspace is mounted at `workspace_path`. Additional mounts map trusted host
directories to absolute virtual paths:

```ruby
policy = {
  workspace_path: "/workspace",
  workspace_access: :read_write,
  mounts: [
    {
      source: "/srv/reference",
      target: "/reference",
      access: :read_only,
      protect_aliases: true
    },
    {
      source: "/var/cache/customer_support",
      target: "/cache",
      access: :read_write,
      tools: false
    }
  ]
}
```

By default, a mount is visible both to isolated processes and to direct
filesystem tools. `tools: false` keeps it available to processes while making
it a deny overlay for the filesystem broker, including through a visible
physical alias. It does not hide the mount from a child process.

`protect_aliases: true` preserves a restrictive mount when the same host files
are reachable through a broader writable mount. Use it for read-only data nested
inside, or aliased into, writable trees.

Bubblewrap's `runtime_roots:`, `tmpfs:`, `masks:`, and `proc:` shape only the
child process view. In particular, a process mask does not restrict direct
filesystem tools; use mount visibility and a Scope for that boundary.

Sandbox limits bound one filesystem-broker read or write, one brokered directory
listing, and the bytes captured from each child output stream. They bound Tool
payloads and model context, not a child process's direct mounted-file I/O, disk
use, CPU, or memory. Apply filesystem quotas and outer process, container, or
hosting limits for those resources. Limits do not turn an unrestricted command
into isolated execution.

## Give each tool the narrowest Scope

Create a Scope at the Tool boundary, not from model arguments:

```ruby
read_reports = run.sandbox.scope(
  mounts: [{target: "/workspace/reports", access: :read_only}],
  capabilities: LittleGhost::Sandbox::Capabilities.new(
    features: %i[filesystem_read filesystem_list]
  ),
  network: false
)
```

Named profiles keep repeated roles in trusted configuration:

```ruby
config.sandbox = lambda do |workspace:, **|
  LittleGhost::Sandboxes::Bubblewrap.new(
    workspace:,
    policy: {
      workspace_access: :read_write,
      mounts: [{source: "/srv/reference", target: "/reference"}],
      network: {mode: :allowlist, allow: ["api.example.com:443"]}
    },
    profiles: {
      editor: {mounts: ["/workspace", "/reference"], network: true},
      reviewer: {
        mounts: [{target: "/workspace", access: :read_only}, "/reference"],
        network: false
      }
    }
  )
end

reviewer_sandbox = run.sandbox.scope(:reviewer)
```

A Scope is effective only when the Tool receives and uses that Scope. Do not
leave the parent Sandbox reachable from untrusted extension code and expect a
child Scope to constrain it.

For Docker, `execution_scope: :command` permits different mount and network
Scopes for different commands. A sandbox-scoped persistent container fixes its
mount and network topology when it starts, so later commands cannot narrow
those parts independently. Writable bind-mounted files persist in both modes.
Process state and unmounted root-filesystem changes persist only in a
sandbox-scoped container.

## Treat networking as a separate enforcement decision

An enforcing backend fills an omitted network policy with `:none`.

- `:none` removes ordinary child-process networking.
- `:inherit` gives the child the backend's ordinary network access.
- `:allowlist` requires exact destinations such as `api.example.com:443` and a
  gateway that the child cannot bypass.

The unrestricted backend supports only `:inherit`. It rejects `:none` and
`:allowlist` because it cannot enforce them.

For Bubblewrap, LittleGhost unshares the network namespace and exposes a Unix
proxy socket through a loopback relay. For Docker, the client joins an internal
network whose egress participant is the gateway. Setting `HTTP_PROXY` or
`HTTPS_PROXY` without removing direct network paths is advisory configuration,
not an allowlist.

The built-in Envoy gateway checks exact DNS names and ports and rejects private
and reserved resolved addresses. CONNECT inspection sees the requested
destination and port, but not methods, paths, headers, or bodies inside an
encrypted tunnel.

Native Envoy can opt into `inspection: :http`. That mode terminates child TLS,
adds a short-lived public CA certificate to the child trust configuration, and
sends bounded headers-only metadata to a trusted authorizer. The CA private key
and authorizer stay outside the child. Clients with certificate pinning or a
custom trust implementation may reject the connection. The Docker Envoy runtime
supports CONNECT allowlisting, not HTTP inspection.

An external gateway declaration lets the application expose an already-managed
proxy through read-only mounts and child-scoped environment values. LittleGhost
validates the declared mount identity and calls the application's readiness
callback, but it cannot attest what the external proxy enforces. The application
owns that proxy's lifecycle, policy, credentials, logs, and failure behavior.

Sandbox network policy applies only to processes launched through that Sandbox.
Provider requests, custom Ruby Tools, hooks, and application services use the
trusted runtime's network. Constrain those separately with application
authorization, least-privilege credentials and IAM, and the hosting platform's
network policy.

## Validate the deployed boundary

Before treating a configuration as an enforcement boundary:

- Run backend probes and real commands inside the final deployment environment.
- Assert that undeclared host paths, sibling Workspaces, and process-only mounts
  cannot be read through filesystem tools.
- Assert that read-only mounts remain read-only through every physical alias.
- Check that the child environment contains only intended values and no host
  credentials.
- Test direct sockets, denied destinations, allowed destinations, gateway
  failure, and an offline Scope separately.
- Pin container images and review runtime roots, wrappers, callbacks, mounts,
  user IDs, and service sockets as trusted configuration.
- Exercise concurrent Runs when roots, caches, gateways, or credentials might be
  shared.
- Observe cleanup failures. LittleGhost attempts to close resources it owns and
  raises when backend cleanup cannot be verified. Workspace teardown controls
  storage removal, and the hosting platform still needs a bounded lifetime and
  orphan-resource strategy.
- Keep the outer runtime's IAM, secrets, inbound access, kernel, daemon, and
  service permissions least-privileged. A child Sandbox does not replace them.

Continue with [Running in Production](production.md) for Runtime reuse,
Sessions, supervision, and observability. The API reference for
{LittleGhost::Workspace}[rdoc-ref:LittleGhost::Workspace],
{LittleGhost::Sandbox}[rdoc-ref:LittleGhost::Sandbox], and
{LittleGhost::Sandbox::Policy}[rdoc-ref:LittleGhost::Sandbox::Policy] provides
the exact constructors and failure contracts.
