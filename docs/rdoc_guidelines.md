# LittleGhost RDoc Guidelines

LittleGhost uses RDoc for its public API reference and for a small set of guides. The documentation should feel like a knowledgeable maintainer sitting beside the reader: warm enough to invite exploration, precise enough that copied code and remembered contracts remain trustworthy.

## Voice: warm and precise

Write directly to the reader in plain language. Begin with what they can accomplish, then name the LittleGhost object that helps them accomplish it. Prefer concrete verbs—“runs,” “returns,” “registers,” “closes”—over abstract phrases such as “provides functionality for.”

Warmth comes from orientation, useful transitions, and examples that respect the reader's time. It does not come from jokes, marketing claims, or conversational filler. Precision comes from source-backed names, signatures, return values, lifecycle facts, and limitations. Do not trade one for the other.

Describe LittleGhost first as a framework for building AI features with agents
and composable assemblies. Make it clear that those features can live inside an
existing Ruby system or support a dedicated AI service. Streaming, tools,
provider adapters, and the dependency profile are important supporting
capabilities, but no one of them is the project's purpose. Examples should show
how those capabilities combine into a useful outcome.

- Use present tense and active voice.
- Use American English and the Oxford comma.
- Begin prose comments with a capital letter and end complete sentences with punctuation.
- Say “you” when guiding an application author. In API comments, name the caller or object when that is clearer.
- Use contractions in guides when they make a sentence sound natural; avoid them where a terse API contract would become ambiguous.
- Prefer one idea per sentence. Define an unfamiliar term on first use.
- State a limitation where the reader encounters it, not in a distant catch-all section.
- Avoid “simple,” “easy,” “obvious,” “just,” and “magic.” They hide prerequisites and make failures feel like the reader's fault.
- Avoid unstable superlatives and claims the code cannot prove.

### Keep reader-facing pages reader-facing

Describe what people can build, how the framework behaves, and the boundaries
they need to use it safely. Do not narrate documentation generation, CI checks,
coverage targets, publication plans, unfinished follow-up work, review process,
or rules for maintainers. Those details belong in this guide, repository agent
instructions, or automation—not in the README, guides, or API comments.

User-facing compatibility and stability information still belongs near the
feature it affects. State it as a fact the reader can act on, such as a required
Ruby version or a pre-1.0 compatibility warning, without turning it into a note
about project process.

## The narrative ladder

Reader-facing pages should move down this ladder in order:

1. **Outcome** — what the reader will be able to build or understand.
2. **Smallest useful path** — the shortest copyable example that reaches that outcome.
3. **Mental model** — how the participating objects divide responsibility.
4. **Working detail** — configuration, lifecycle, extension points, and alternatives.
5. **Boundaries** — security, persistence, concurrency, failure, or compatibility constraints.
6. **Next step** — a link to the next guide or the relevant API object.

Do not make a newcomer learn provider inheritance, event internals, or every DSL before seeing an agent answer a request. Do not make an experienced reader wade through a tutorial to find a method contract. The page's depth determines where it joins the ladder.

## Page depth and purpose

| Page | Reader's question | Expected depth |
| --- | --- | --- |
| `README.md` | “What can this do, and where do I start?” | Roughly 600–900 words. One compact end-to-end example, one architecture map, installation, documentation links, compatibility status, license, and essential contribution commands. |
| Getting Started | “How do I make the first useful agent run?” | One complete path from installation through output and streaming. Explain only concepts used on that path. |
| Concept guide | “How do these pieces relate, and when do I choose each one?” | A durable mental model, contrasting adjacent choices with connected examples. Link out instead of cataloguing every option. |
| Class or module comment | “What responsibility does this object own?” | A purpose sentence, lifecycle or extension contract, and a short canonical example for a core type. |
| Method comment | “What happens if I call this?” | Usually one sentence plus non-obvious arguments, return value, side effects, exceptions, or constraints. |
| Extension contract | “What must my implementation provide?” | The smallest valid implementation, ownership and concurrency expectations, accepted and returned shapes, and failures the framework handles. |
| Value object or error | “What does this value mean, or when can I rescue this?” | One focused description. Document meaningful fields and recovery behavior; omit an example when it would only repeat the initializer. |

Keep each page responsible for one level. The README should not become a complete manual, a guide should not duplicate the API reference, and API comments should not retell the architecture.

Use the same customer support story across introductory documentation so readers learn LittleGhost rather than a new domain on every page:

- `LittleGhost::ModelResolver` maps the logical `customer_support` role to a provider.
- `CustomerSupportAgent` answers the customer.
- `HelpCenterLookupTool` reads help center information through a narrow, validated lookup.
- `ResearchAgent` handles open-ended investigation.
- `ResponseWorkflow` composes deterministic research and response steps.
- `ProblemSolverSwarm` lets configured specialists hand work directly to one another.
- `SupportFlowGraph` follows application-declared nodes and edges.

Other examples are welcome when a feature cannot be explained honestly through this story.

## Public API boundary

A symbol appearing in the generated API reference is an intended integration point. LittleGhost is pre-1.0 and may still change, but documented behavior should not change casually or accidentally.

- Document public classes, modules, methods, attributes, constants, and DSLs that application authors call, subclass, implement, or rescue.
- Add `:nodoc:` to a Ruby-public symbol that exists only so framework internals can collaborate. Prefer normal Ruby `private` or `protected` visibility when the implementation allows it.
- Add `:doc:` only to a non-public hook that callers intentionally override or use from a subclass, such as a workflow implementation hook.
- Do not hide an ambiguous API merely to improve the coverage percentage. Decide whether it is public first.
- A change to a documented public contract must update its RDoc in the same change.

The `rdoc:coverage` task is an inventory, not a release gate. Coverage becomes meaningful only after the visible API surface is curated.

## Class and module comments

Place a comment immediately before the definition. Start with the object's purpose and responsibility, then explain its lifecycle or extension contract. Include one short, canonical example for each core class or module.

```ruby
# Resolves logical model roles to provider-backed models.
#
# Profiles use application-level names so agents do not depend on provider
# model identifiers.
#
#   providers = LittleGhost::Providers::Configuration.new(
#     openai: {adapter: :openai, api_key: ENV.fetch("OPENAI_API_KEY")}
#   )
#   resolver = LittleGhost::ModelResolver.new(
#     providers:,
#     profiles: {customer_support: {target: "openai:gpt-5.6-luna"}}
#   )
#   resolver.resolve("customer_support")
class ModelResolver
end
```

Document the behavior an application observes. Avoid narrating the internal algorithm, restating the class name, or describing code that is already obvious.

## Method comments

Lead with the contract in natural present-tense prose. “Returns…”, “Builds…”, and “Registers…” are useful when they are the clearest verbs, but do not force every method into the same opening. Add only the contract details callers need:

- What each non-obvious argument represents.
- Defaults that change behavior.
- The returned object or yielded values.
- Observable side effects and lifecycle ownership.
- Important edge cases and exceptions callers may handle.
- Threading, persistence, trust, or security constraints.

Do not use YARD-only tags such as `@param` or `@return`. Write ordinary prose and RDoc lists instead:

```ruby
# Registers a tool for the agent.
#
# +tool+ may be a LittleGhost::Tool class or instance.
#
# Options are:
#
# [+:replace+]
#   Replaces an existing tool with the same model-visible name.
```

## Extension contracts and small reference pages

An extension contract is successful when a reader can implement it without
reading LittleGhost internals. Show the required method or subclass hook, then
state who creates and closes the object, whether calls may overlap, which
values cross the boundary, and how errors are reported. Keep optional hooks
separate from the minimum working implementation.

Value objects and error classes should stay small. Explain the distinction the
type preserves—for example, why one terminal outcome differs from another—not
every inherited Ruby method. For an error, say what condition raises it and
what a caller can reasonably do next. An empty example adds less value than a
precise sentence.

## Examples, jargon, and warnings

Examples demonstrate the preferred public API, not every possible form. Keep a single example internally consistent: names, roles, input keys, return objects, and output should agree. Before writing one, inspect the implementation and tests for every non-trivial call it uses.

- Indent Ruby examples by three spaces after the comment marker.
- Put expression results after `# =>` and align them when several results are shown.
- Do not use `puts` or `p` merely to display an expression result. Use them only when writing output is the behavior being demonstrated.
- Use `==== Examples` only when a longer comment needs a distinct examples section.
- Prefix shell commands with `$`. Use paths relative to the repository or application root.
- Show modern LittleGhost idioms. Do not invent convenience APIs or conceal required setup.
- Prefer a small literal data source over an unrelated database or network dependency.
- If an excerpt intentionally omits setup, say what was omitted and link to the complete example.

For predicates and flags, describe the boolean meaning instead of promising an
exact `true` or `false` object unless callers genuinely depend on that exact
return value.

Use LittleGhost's own vocabulary consistently. A **model role** is the application-facing name resolved by `ModelResolver`; a **provider** performs model requests; a **run** owns one top-level execution; an **assembly** is any agent-compatible coordination; a **subagent** is model-directed delegation; a **workflow** is Ruby-directed composition; a **swarm** uses direct agent handoffs; and a **graph** follows declared nodes and edges. Do not switch casually between “agent,” “assistant,” “bot,” “worker,” and “model.”

Warnings are for plausible harm or surprising irreversible behavior, not emphasis. Start with **Warning:**, name the risk, then give the safe action. Examples that grant filesystem, process, network, credential, or cross-tenant data access must put the trust boundary next to the enabling code. Use **Note:** for useful, non-hazardous context. If ordinary prose is clear enough, use ordinary prose.

## A golden before and after

Before, the comment repeats the method name, leaves ownership unclear, and uses vague jargon:

```ruby
# Handles running an agent with options.
#
# This is an easy helper that processes everything and gives you the result.
def ask(message, **options)
end
```

After, the reader can predict the observable contract:

```ruby
# Executes +message+ to completion and returns the owning LittleGhost::Run.
#
# The run checkpoints its session and closes registered resources before
# returning. Use Agent.stream_ask when the caller needs
# LittleGhost::StreamEvent objects as work progresses.
def ask(message, **options)
end
```

The improved version is not longer because length is virtuous. It is longer because return type, lifecycle, and the adjacent streaming choice are the facts a caller needs.

## RDoc markup and links

Ruby comments use native RDoc markup. `README.md` and public guides use Markdown and become generated documentation pages.

- Mark simple code identifiers with `+identifier+`; use `<tt>...</tt>` for complex inline code containing spaces or markup characters.
- Use `=`, `==`, and `===` headings sparingly inside long class or module docs.
- Refer to a local instance method as `#method` and a class method as `ClassName.method`.
- Prefer explicit `rdoc-ref:` links when automatic linking could be ambiguous: `Agent[rdoc-ref:LittleGhost::Agent]` or `ask[rdoc-ref:LittleGhost::Agent#ask]`.
- Do not link to generated HTML paths or a future documentation hostname. Those links break across themes, versions, and preview builds.

The RDoc task warns when an explicit `rdoc-ref:` cannot be resolved.

## Generated and implementation-shaped APIs

RDoc cannot infer every DSL or metaprogrammed declaration. Start its standalone documentation block with `##` and use the appropriate directive:

```ruby
##
# Registers a callback that runs before a model request.
# :singleton-method: before_model
# :call-seq:
#   before_model(method_name = nil, &block)
```

Available directives include `:method:`, `:singleton-method:`, `:attr_reader:`, `:attr_writer:`, and `:attr_accessor:`. Use `:call-seq:` when the implementation signature exposes sentinels, forwarding arguments, generated forms, or overloads that are not useful to readers. Use `:args:` or `:yields:` only when RDoc's inferred arguments are wrong.

Do not add manual directives for ordinary Ruby methods whose public signature is already clear. Keep one canonical block for each generated method; duplicate inferred and manual entries are a documentation defect.

RDoc sees a class created with `Data.define` as a constant assignment. When that
value is public, follow the assignment with a no-op class reopening that contains
the class narrative and standalone directives for its generated readers and any
methods RDoc could not infer:

```ruby
Result = Data.define(:value) # :nodoc:

# Carries the validated value returned by an operation.
class Result < Data # :doc:
  ##
  # :attr_reader: value
  # The validated application value.
end
```

The paired directives replace the assignment-level constant entry with one
class page and avoid duplicate search results. This gives the value an API page
without redefining generated readers. Keep the reopening documentation-only,
and verify both runtime behavior and the rendered page whenever the value
changes.

## Review rubrics

An agent preparing documentation should verify:

- Every example name and signature against current source or tests.
- Every public symbol added or changed has an intentional RDoc state: documented, non-public, or explicitly `:nodoc:`.
- The page follows the narrative ladder and stays at its assigned depth.
- Jargon is defined once and reused consistently.
- Security and lifecycle boundaries appear beside the API that creates them.
- Reader-facing prose contains no documentation process, CI, coverage, publication planning, or maintainer instructions.
- The generated page, navigation, signatures, links, and metadata were inspected rather than inferred from source rendering.
- Only owned files changed and generated output is not staged.

A human reviewer should be able to answer “yes” to these questions:

1. Can a new reader identify the outcome and first useful step in under a minute?
2. Can an experienced reader find the public contract without reading a tutorial?
3. Would copying the example call real APIs with the shown argument shapes?
4. Are the return value, ownership, and important failure modes unambiguous?
5. Does the text distinguish model-directed delegation from application-directed workflow control?
6. Are warnings concrete, proportional, and paired with a safe action?
7. Does the generated site look intentional rather than merely compile?

## Generated-site validation

Run the documentation tasks before submitting changes:

```sh
bundle exec rake rerdoc
bundle exec rake rdoc:coverage
```

Open `doc/rdoc/index.html` and inspect the landing page plus every materially changed guide and API page. Generated files stay under `doc/rdoc/` and are never committed.

Check both content and generated metadata:

- The landing-page browser title is “LittleGhost API Documentation”; guide and API page titles also include that configured project title.
- The landing-page description begins with LittleGhost's capability, not project history or development status.
- `README.md` is the landing page, Getting Started and Core Concepts appear under Pages, and this contributor guideline does not.
- Page titles, headings, code blocks, tables, navigation, and explicit cross-references render correctly.
- Public method signatures match the source, with no duplicate generated entries.
- Pages navigation contains the intended guides, and search data contains the expected public API names without exposing internal-only pages.
- No absolute local paths, credentials, generated HTML links, or stale future documentation URLs appear.

Then run the repository checks applicable to the change:

```sh
bundle exec rake test
bundle exec standardrb --no-fix
```

The CI documentation build validates generation and explicit references. It does not publish a site or enforce a coverage percentage.
