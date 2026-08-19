# Give Agents Skills

A Skill is a reusable instruction package that an Agent can discover by name
and load when a task needs it. Skills keep specialized procedures out of the
Agent's main prompt.

## Write one focused skill

Create `app/skills/refund_guide/SKILL.md`:

```markdown
---
name: refund_guide
description: Determine which refund guidance applies to a customer request.
allowed-tools:
  - help_center_lookup
compatibility: Requires the refunds help-center collection.
---

# Apply the refund guidance

1. Load the current refund entry with `help_center_lookup`.
2. Compare the purchase date and item category with the returned guidance.
3. State which facts support the decision and which facts are still missing.
4. Return the analysis to the application instead of issuing a refund.
```

Each immediate child of a configured skill root may contain one `SKILL.md`.
Front matter requires a single-line `name` and `description`. Names contain
only letters, numbers, underscores, and hyphens. `allowed-tools` and
`compatibility` are optional information shown to the model.

A Skill may also include supporting files in `references/`, `scripts/`, or
`assets/`. Keep the main instructions short and point to a resource only when
the task needs it.

## Let an Agent discover skills

The conventional root is `app/skills`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use an available skill when a request needs a documented procedure."
  tools HelpCenterLookupTool
  skills
end
```

At runtime, the Agent receives a short catalog of skill names, descriptions,
and locations. The generated `skills` Tool loads the full instructions when
the model selects one. An empty catalog adds nothing to the prompt and no Tool.

You can use another application-owned directory or expose only selected
skills:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  skills paths: [File.expand_path("../../support_skills", __dir__)],
    only: %w[refund_guide]
end
```

Paths may also come from a callable resolved for each Run. Build the path from
application configuration, not from a path supplied by the model or request.

## Pair instructions with Tools

`allowed-tools` tells the model which Tools a Skill expects. It doesn't add or
enable those Tools. The Agent's `tools` declaration remains the source of what
the model can call, and each Tool applies its normal application checks.

This separation makes Skills safe to use as guidance: changing a Markdown file
can change what the Agent tries, but it can't grant a new Tool, provider,
filesystem path, or credential.

> **Safety note:** Keep configured skill directories under application control
> and review Skill changes as prompt changes. A Skill can contain mistaken or
> outdated instructions, so application code should continue to check any
> operation that has side effects.

## Make resources available to code mode

Ordinary Skill loading needs no Workspace configuration. If model-authored code
also needs to read Skill resources, give those resources a stable model-visible
location:

```ruby
require "fileutils"
require "tmpdir"

skill_root = File.expand_path("../../app/skills", __dir__)

LittleGhost.configure do |config|
  config.skill_paths = [skill_root]
  config.skill_resource_root = "workspace://skills"

  config.workspace = lambda do |**|
    root = Dir.mktmpdir("little-ghost-skills-")
    LittleGhost::Workspace.new(
      root:,
      paths: {skills: skill_root},
      teardown: lambda do |workspace:, **|
        FileUtils.remove_entry_secure(workspace.root) if File.exist?(workspace.root)
      end
    )
  end

  config.sandbox = {
    provider: :native,
    files: {root: :read_write, skills: :read_only},
    root_filesystem: :isolated,
    network: :none
  }
end
```

The named Workspace path maps the configured Skill directory, and the Sandbox
makes it readable without allowing model-authored code to change it. The model
can then ask the Filesystem Tool for a path such as
`workspace://skills/refund_guide/references/example.md` without learning the
host's directory layout. [Workspaces and Sandboxes](sandboxing.md) explains how
to adapt the temporary root, backend, and other grants for your application.

## Write instructions that stand on their own

A useful Skill tells the Agent:

- When the procedure applies.
- Which information it needs before deciding.
- Which named Tools or resources help.
- What result the caller expects.
- Which action remains with the application.
- What to do when information is missing or conflicts.

Use direct instructions and stable domain language. Avoid repeating the
Agent's general prompt or relying on Tool behavior that the Tool description
doesn't promise.

Continue with [Workspaces and Sandboxes](sandboxing.md) when model-authored code
needs Skill resources. See [Tools](tools.md) for Tool validation, bindings, and
side effects.
