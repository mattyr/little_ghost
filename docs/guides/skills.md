# Give Agents Skills

A Skill is an application-authored instruction package that an Agent discovers
by name and loads only when it needs the full procedure. Skills keep specialized
guidance out of every prompt while leaving Tool authority in application code.

## Write one focused skill

Create `app/skills/refund_policy/SKILL.md`:

```markdown
---
name: refund_policy
description: Determine which refund policy applies to a customer request.
allowed-tools:
  - help_center_lookup
compatibility: Requires the refunds help-center collection.
---

# Apply the refund policy

1. Load the current refund entry with `help_center_lookup`.
2. Compare the purchase date and item category with the returned policy.
3. State which facts support the decision and which facts are still missing.
4. Do not approve or issue a refund; return the analysis to the application.
```

Each immediate child of a configured skill root may contain one `SKILL.md`.
Front matter requires a single-line `name` and `description`. Names contain only
letters, numbers, underscores, and hyphens. `allowed-tools` and `compatibility`
are optional metadata shown to the model.

Resources may live in `references/`, `scripts/`, or `assets/` beneath the skill
directory. Keep the main instructions focused and direct the model to a resource
only when the task needs it.

## Enable discovery on an Agent

The conventional root is `app/skills`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use the available skill when a request needs a documented procedure."
  tools HelpCenterLookupTool
  skills
end
```

At runtime, the Agent's system message receives a short escaped catalog of
names, descriptions, and locations. The `skills` Tool loads the selected
instructions. An empty catalog adds neither discovery text nor a Tool.

Use an explicit trusted root when the skills live elsewhere:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  skills paths: [File.expand_path("../../support_skills", __dir__)],
    only: %w[refund_policy]
end
```

Paths may also come from a callable resolved for each Run. That callable is
trusted application policy: derive its choice from authenticated tenant or
deployment configuration, never from a model-supplied path.

## Keep instructions separate from authority

`allowed-tools` documents what a Skill expects; it does not install, enable, or
authorize those Tools. The Agent's Tool declarations decide what is available,
and each Tool must authorize its own operation from application-established
identity and context.

A Skill can be wrong, stale, or manipulated just like any other prompt input.
It must not be able to grant filesystem access, expose credentials, relax
Sandbox policy, select an unapproved provider, or bypass a Tool's validation.
Review a skill change with the same care as code that changes model behavior.

Keep configured roots application-owned and non-user-writable. The catalog
rejects symbolic-link escapes and bounds skill counts, file sizes, resource
counts, and resource depth, but those checks do not make an untrusted author
safe.

## Expose stable resource locations

Without a `skill_resource_root`, catalog locations are process-visible paths.
When model-authored code needs resources, map the skill root into a Workspace
and expose a model-visible reference:

```ruby
LittleGhost.configure do |config|
  config.skill_paths = ["app/skills"]
  config.skill_resource_root = "workspace://skills"
end
```

The current Workspace must map the `skills` name to every configured skill root,
and the bound Sandbox must expose it through a read-only file grant. LittleGhost
rejects writable Tool-visible aliases it can identify. The application must
also ensure an outer container or mount namespace does not expose the same
physical files through another writable path.

A `workspace://skills/refund_policy/references/example.md` reference describes
where a model can ask the Filesystem Tool to read a resource. It does not give
arbitrary Ruby code or a process new authority.

## Make a skill operationally complete

A useful skill tells the Agent:

- When the procedure applies and when it does not.
- Which evidence to collect before deciding.
- Which named Tools or resources it may need.
- What output or handoff the caller expects.
- Which action remains application-owned.
- How to handle missing, conflicting, or stale information.

Use direct instructions and stable domain language. Avoid restating the Agent's
general prompt, embedding credentials, relying on undocumented Tool behavior,
or telling the model to ignore higher-priority instructions.

Before release, load the catalog in a test, confirm the expected skill names,
inspect `discovery_prompt`, activate each changed skill through the generated
Tool, and verify every listed resource resolves inside the intended boundary.

Continue with [Tools](tools.md) for validation and authorization, and
[Workspaces and Sandboxes](sandboxing.md) when a skill's resources must be
available to model-authored code.
