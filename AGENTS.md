# LittleGhost Contributor Instructions

## Project shape

LittleGhost is a Ruby framework for adding agents and agentic workflows to an
existing Ruby system or using them as the core of a dedicated AI service. It is
distributed as the `little_ghost` gem and supports Ruby 3.3 and newer.

Keep the framework useful as an embeddable library:

- `lib/little_ghost/` contains framework code and optional integrations.
- `test/` contains the Minitest suite and mirrors the framework by feature.
- `docs/guides/` contains reader-facing guides included in the gem.
- `README.md` is both the repository introduction and RDoc landing page.
- `Rakefile` defines the test and documentation builds used by CI.

The core should remain provider-neutral and dependency-light. Agents express
behavior, tools expose narrow application operations, model registries resolve
logical roles, providers translate model APIs, runs own top-level lifecycle,
and session stores own persistence.

## Working rules

- Read the surrounding implementation and tests before changing behavior.
- Keep changes focused. Do not refactor unrelated code while implementing a
  feature or fix.
- Preserve existing work in a dirty worktree. Never discard or rewrite changes
  that are outside the task.
- Do not alter observable behavior merely to satisfy a test or coverage tool.
- Treat concurrency, cancellation, deadlines, resource cleanup, and telemetry
  as part of the behavior being changed, not as follow-up concerns.
- Do not introduce compatibility shims or deprecated paths unless the task
  explicitly requires them.

## Code standards

Write idiomatic Ruby that passes Standard Ruby. `.standard.yml` targets Ruby
3.3 syntax even when CI runs a newer Ruby, so changes must remain compatible
with the gem's declared minimum version.

- Begin Ruby files with `# frozen_string_literal: true`.
- Prefer small, cohesive objects and explicit keyword arguments over implicit
  mutable option bags.
- Follow nearby naming and namespace patterns. Framework errors belong under
  `LittleGhost` and should describe a failure callers can act on.
- Do not rescue broad exceptions unless the boundary must translate them.
  Preserve unexpected programmer and provider errors rather than masking them.
- Protect shared mutable state. Keep lock scope clear, avoid calling unknown
  application code while holding a lock, and make cleanup safe after partial
  initialization.
- Use monotonic time for elapsed-time and deadline calculations.
- Keep ownership explicit. Objects that open resources should close them, and a
  run should release owned resources in reverse order.
- Avoid comments that restate code. Use prose comments for non-obvious reasons,
  lifecycle constraints, security boundaries, or compatibility behavior.
- Avoid block-style section comments inside implementation code.

Run formatting as a check; do not use automated formatting to rewrite unrelated
files:

```sh
bundle exec standardrb --no-fix
```

## Testing and verification

Tests use Minitest. Test files end in `_test.rb`, require `test_helper`, and name
test methods after observable behavior.

- Add or update tests with every behavior change and regression fix.
- Keep scenario-defining setup visible in the test. Extract helpers only when
  they remove repetition without hiding the state that makes the case useful.
- Assert outcomes and externally visible state, not private implementation
  steps.
- Use fake providers, transports, clocks, stores, and application objects.
  Tests must not require network access, cloud credentials, or paid APIs.
- Keep tests deterministic. Coordinate threads explicitly and use bounded
  waits; do not depend on arbitrary sleeps or execution order.
- Restore environment variables and process-wide configuration after tests that
  change them. `test_helper` already isolates instrumentation and event state.
- Cover successful behavior, invalid input, failure propagation, and relevant
  cancellation, deadline, concurrency, or cleanup paths.

Run the narrowest affected file while iterating:

```sh
bundle exec ruby -Itest test/model_registry_test.rb
```

Before considering a change complete, run the full local gate:

```sh
bundle exec rake test
bundle exec standardrb --no-fix
git diff --check
```

CI runs the full test suite and formatter check. A local failure must be fixed
before pushing; do not rely on CI to discover known failures.

## Dependencies and integrations

- Prefer the Ruby standard library and existing dependencies.
- Add a runtime dependency only when the core requires it. Provider SDKs and
  exporters that are not required for normal gem loading should remain optional
  and load only when their integration is used.
- Keep `Gemfile.lock` and `little_ghost.gemspec` consistent when dependencies
  change.
- Requiring `little_ghost` must work without optional provider SDKs installed.
- Provider adapters consume `ModelRequest`, emit normalized `StreamEvent`
  values, and return `ModelResponse`; do not leak vendor response shapes into
  agents, tools, or runs.
- Preserve cancellation and deadlines across provider, tool, workflow, and
  subagent boundaries.

## Security and trust boundaries

- Treat prompts, model output, tool arguments, remote provider payloads, MCP
  responses, and persisted session data as untrusted input.
- JSON schema validation checks shape; it does not authorize an operation.
  Tools must enforce application authorization using trusted run context.
- Never place credentials, tokens, raw authorization headers, or customer data
  in examples, fixtures, logs, exception messages, or telemetry attributes.
- Keep model and provider selection, settings, filesystem roots, and sandbox
  configuration under trusted application control. Do not copy unchecked
  request or model values into these controls.
- Do not describe the unrestricted sandbox as containment. It runs with the
  Ruby process's permissions and is not a security boundary.
- Make external data movement explicit for providers, telemetry exporters,
  session stores, and MCP servers. Filtering or pseudonymizing identifiers does
  not make remaining content anonymous.
- Error messages returned to models or end users must be safe to disclose;
  retain detailed exceptions only in trusted application channels.

## Documentation

Every change to public behavior must update its adjacent RDoc in the same
change. Follow `docs/RDOC_GUIDELINES.md` for voice, page depth, markup,
examples, Data-defined value pages, and the review rubric.

- Lead with the useful outcome, then explain the object and its lifecycle.
- Document observable behavior, arguments, return values, ownership, failure
  modes, concurrency, and trust boundaries where they matter.
- Keep examples small, complete, executable, and consistent with the customer
  support story used by the introductory guides.
- Keep reader-facing prose free of CI notes, coverage targets, publication
  plans, review process, maintainer rules, and unfinished project work.
- Mark implementation-only Ruby-public symbols with `:nodoc:` deliberately.
  Use `:doc:` only for non-public hooks that application authors intentionally
  override.
- Do not hide an unclear API merely to improve coverage. Decide whether it is a
  supported integration point first.
- Do not commit generated files under `doc/rdoc/`.

For public API or documentation changes, run both documentation tasks:

```sh
bundle exec rake rerdoc
bundle exec rake rdoc:coverage
```

Inspect the generated landing page and each materially changed guide or API
page. Verify navigation, signatures, links, code rendering, titles, metadata,
and the absence of internal-only pages or duplicate entries. CI validates the
documentation build; publishing a documentation site is outside the current
workflow unless a task explicitly adds it.

## Git and pull requests

- Never push directly to `main`. All changes go through a pull request.
- Before every push, confirm the current branch is not `main`.
- Do not include issue, ticket, or project-tracking identifiers in branch names,
  commit messages, pull-request titles, or pull-request descriptions. Use plain,
  descriptive wording.
- Keep commits focused and describe the behavior or documentation changed.
- Open pull requests as drafts unless the user explicitly requests otherwise.
- Do not merge a pull request without explicit user instruction.

Use a concise pull-request description:

```markdown
## Summary
- What changed and why

## Verification
Automated: Tests, formatting, and other checks that passed.
Manual: Anything that still needs human verification before merge.
```

Do not use unchecked task lists as a test plan.
