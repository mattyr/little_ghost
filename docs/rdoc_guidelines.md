# LittleGhost RDoc Guidelines

LittleGhost uses RDoc for its public API reference and for a small set of guides. The documentation should feel like a knowledgeable maintainer sitting beside the reader: warm enough to invite exploration, precise enough that copied code and remembered contracts remain trustworthy.

## Voice: warm and precise

Write directly to the reader in plain language. Begin with what they can accomplish, then name the LittleGhost object that helps them accomplish it. Prefer concrete verbs—“runs,” “returns,” “registers,” “closes”—over abstract phrases such as “provides functionality for.”

Warmth comes from orientation, useful transitions, and examples that respect the reader's time. It does not come from jokes, marketing claims, or conversational filler. Precision comes from source-backed names, signatures, return values, lifecycle facts, and limitations. Do not trade one for the other.

Describe LittleGhost first as a Ruby library for building AI features with
agents and composable assemblies. Use “framework” only for a specific body of
behavior, such as its lifecycle or event framework. Make it clear that those
features can live inside an existing Ruby system or support a dedicated AI
service. Streaming, tools, provider adapters, and the dependency profile are
important supporting capabilities, but no one of them is the project's purpose.
Examples should show how those capabilities combine into a useful outcome.

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
5. **Essential considerations** — the limits or failure behavior the reader
   needs before using the feature.
6. **Next step** — a link to the next guide or the relevant API object.

Do not make a newcomer learn provider inheritance, event internals, or every DSL before seeing an agent answer a request. Do not make an experienced reader wade through a tutorial to find a method contract. The page's depth determines where it joins the ladder.

Excitement comes from visible progress. Let the reader run one Agent before
defining a Tool, then let that same calling style grow into an Assembly. Prefer
short transitions such as “Now give it real application data” over claims that
the library is effortless. Each page should earn the next click with a useful
result or a newly unlocked capability.

## Write for an interested Ruby engineer

Picture a Ruby engineer who wants to add AI to an application and has never
seen LittleGhost. They know Ruby, classes, blocks, initializers, and application
boundaries. They do not know LittleGhost's vocabulary, its implementation, or
what earlier versions of its documentation used to say.

That reader should come away with a few steady impressions:

- LittleGhost feels like Ruby. The smallest useful path uses familiar classes,
  methods, and files rather than framework ceremony.
- A feature can start with one Agent and grow without changing how application
  code calls it.
- Advanced control is available when the application needs it, but it does not
  crowd the first path.
- The documentation is candid about data flow, permission checks, failures,
  and ownership without making ordinary usage feel risky or burdensome.
- Each page answers the question raised by the page before it and makes the next
  useful step feel within reach.

Write from the reader's current knowledge, not the maintainer's memory. Never
explain a new design by contrasting it with an old one the reader has not seen.
For example, “you do not need to store a second object anymore” is confusing;
“configure LittleGhost once during application startup” gives the reader a
complete instruction. Introduce a name before depending on it. If a sentence
needs three new terms, split the idea or move it later.

Before 1.0, reader-facing guides describe the current contract directly. Do not
add migration sections, removed option lists, or replacement histories. Keep
that context in release notes or maintainers' records when it is useful.

Treat every sentence as part of a path of discovery. Lead with the result, then
add the mechanism or boundary that helps the reader use it. Prefer two short
sentences over one sentence that compresses setup, lifecycle, concurrency, and
failure behavior. A useful technical term is welcome once it has a clear job;
an abstract phrase that merely sounds precise is not.

Reference pages are different entry points. Some repetition there is useful
because a reader may arrive directly from search. Repeat the local contract,
return type, ownership, or adjacent choice when it helps that page stand alone.
Do not repeat whole guide narratives or unrelated architecture.

### Run a cold-reader pass

For a substantial documentation change, review the rendered site in the
same order a newcomer would encounter it: homepage, docs home, top-level guides,
then a few central API pages. Use a reviewer with no LittleGhost context when
possible. After each page, record:

- What the reader believes LittleGhost is and what they now know how to do.
- Which assumptions they made from everything read so far.
- Any concept, sentence, or phrase that arrived before it had context.
- Any wording that felt dense, abstract, clinical, repetitive, or unlike a
  human explaining Ruby to another Ruby engineer.
- Whether the page created visible progress and a natural reason to continue.

Fix the journey, not only the isolated sentence. Move an explanation earlier
when several later passages depend on it. Remove a detail when the introductory
path does not need it. Keep a boundary beside the feature that creates it, but
rewrite it in approachable language rather than hiding it in a late disclaimer.

## Page depth and purpose

| Page | Reader's question | Expected depth |
| --- | --- | --- |
| `README.md` | “What can this do, and where do I start?” | Roughly 600–900 words. One compact end-to-end example, one architecture map, installation, documentation links, compatibility status, license, and essential contribution commands. |
| Getting Started | “How do I make the first useful agent run?” | One complete path from installation through output and streaming. Explain only concepts used on that path. |
| Core Concepts | “How do these pieces relate, and when do I choose each one?” | A durable mental model from Agent to Assembly, contrasting adjacent choices without cataloguing their options. |
| Models and Providers | “How do I choose where an Agent sends a request?” | Start with one direct target, then introduce shared roles, connections, per-request selection, and capabilities. |
| Assembly guide | “How do I compose several participants?” | Connected, runnable examples of Workflow, Swarm, Graph, nesting, trajectories, and builders. |
| Prompts as Views | “Where do growing instructions and shared prompt pieces live?” | Move one inline prompt into a conventional ERB view, then introduce locals, partials, and lookup. |
| Tools | “What can an agent do, where does that code run, and where is it authorized?” | Tool definition and binding, trusted context, direct application authority, sandbox delegation, concurrency, retries, failures, and the bridge to code mode. |
| Structured Results and Content | “How do I receive checked values or send images and documents?” | One strict result schema, strategy selection, repair behavior, and typed content blocks. |
| Skills | “How do I package reusable instructions and resources?” | One focused Skill, discovery, Tool pairing, optional Workspace resources, and writing guidance. |
| Workspaces and Sandboxes | “What runs where, what persists, and which process boundaries are enforced?” | Workspace and resource lifecycle, logical paths, scoped capabilities, backend tradeoffs, networking, hosting layers, and explicit limitations. |
| Code Mode | “How can a model compose Tools without gaining their authority?” | One useful Ruby program, trusted Tool boundary, execution lifecycle, excluded Tools, limits, optional JavaScript, engine extensions, and sandbox requirements. |
| Integrations | “How do I connect remote Tools, interfaces, and tracing?” | Small MCP, AG-UI, and OpenTelemetry recipes, each followed by its immediate operational considerations. |
| Production guide | “How does this live in a real application?” | Configuration, runtime reuse, sessions, supervision, observability, and ownership. |
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
#     openrouter: {adapter: :open_router, api_key: ENV.fetch("OPENROUTER_API_KEY")}
#   )
#   resolver = LittleGhost::ModelResolver.new(
#     providers:,
#     profiles: {customer_support: {target: "openrouter:openai/gpt-5.6-luna"}}
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
- Threading, persistence, or safety constraints that change how callers use the
  method.

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

## Examples, jargon, and safety notes

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

Write the default, productive path first. Add deeper mechanics only when they
help the reader choose or debug something on that page. A guide should feel
safe to follow without asking the reader to perform a security review before
every example.

Prefer concrete actors and actions over institutional shorthand. Phrases such
as “application policy,” “trust boundary,” “authorization boundary,” and
“untrusted input” often hide the useful instruction. Say who chooses the value,
where code runs, or what the application must check. Precise API and domain
names such as `Sandbox::Policy` and “refund policy” remain correct. These terms
are review prompts, not banned words.

Do not introduce implementation nouns as if readers already know them. Describe
the observable behavior first. For example, say that changing a builder affects
future builds without changing an assembly already built; do not lead with
“immutable snapshot” or “recorded and replayed.” Use “snapshot” only for an
actual point-in-time record exposed by the public API, and define it on first
use.

Use a Markdown blockquote beginning with `> **Safety note:**` when a plausible
harm needs to stand apart from the learning flow. Give one concrete safe action
and keep the aside as close as possible to the code that creates the risk.
Combine repeated cautions instead of scattering them across a page. Use no more
than one Safety note per major topic. Use `> **Note:**` for helpful context and
`> **Advanced:**` for optional mechanics. If ordinary prose is clear enough,
use ordinary prose.

Place machine-readable discovery near the top of a documentation landing page
as a short aside, after the reader has enough context to understand the project.
Link concise labels such as `llms.txt`; do not make a raw URL a hero message or
present agent discovery as the first documentation chapter.

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

## Machine-readable documentation surface

The published documentation is one body of content with HTML and Markdown
representations. A representation for a model or agent is not a second set of
documentation and must not be maintained independently from the source that
people read.

- Every content-bearing HTML page has a stable Markdown counterpart generated
  from the same README, guide, homepage content, or RDoc object store. Do not
  convert rendered HTML back into Markdown.
- Each HTML page declares its Markdown counterpart with
  `<link rel="alternate" type="text/markdown">` and an absolute, visually
  hidden pointer. The pointer is `aria-hidden="true"`; it is machine discovery
  metadata, not duplicate navigation for assistive technology.
- Canonical URLs use `https://mattyr.github.io/little_ghost/`, the published
  GitHub Pages site. Each Markdown representation has its own stable `.md` URL;
  request-time content negotiation is not required.
- A versioned page links only to content generated from the same release. Current
  content and historical APIs must never be combined in one Markdown page or
  full-text corpus.

`/llms.txt` is a concise orientation document in the llmstxt.org shape. It
states what LittleGhost is, distinguishes the learning paths, and links only to
the most useful canonical Markdown pages. It is not a sitemap or a dump of page
titles. `/llms-full.txt` is the deterministic current corpus: docs home, guides in
navigation order, API index, essential APIs, then remaining public APIs in
alphabetical order. Each document appears once under its canonical Markdown
URL. Historical releases produce their own discovery files from that release.

`robots.txt` allows documentation crawlers and publishes this owner-approved
content signal:

```text
Content-Signal: search=yes, ai-input=yes, ai-train=yes
```

The signal expresses permission; it does not make unpublished information
appropriate for the public documentation.

Prefer content quality over model-specific markup. Define concepts directly,
use descriptive headings, make examples complete, and cite authoritative
primary specifications when an external contract matters. Do not invent
statistics, testimonials, or citations. Do not add `ai.txt`, AI-specific meta
tags, hidden prompt comments, user-agent routing, an “AI mode” toggle, a
duplicate AI-only information page, or JSON-LD solely to attract models.

Documentation review must include evidence from the built artifact. A clean
review records the changed source pages, applicable standards, rendered pages
inspected, link and reference checks, Markdown counterparts, discovery files,
and release isolation. Missing required source or rendered output is a finding,
not an assumed pass.

## Review rubrics

An agent preparing documentation should verify:

- Every example name and signature against current source or tests.
- Every public symbol added or changed has an intentional RDoc state: documented, non-public, or explicitly `:nodoc:`.
- The page follows the narrative ladder and stays at its assigned depth.
- Jargon is defined once and reused consistently.
- Safety and lifecycle notes are concrete, proportional, and appear beside the
  API that creates the need for them.
- Reader-facing prose contains no documentation process, CI, coverage, publication planning, or maintainer instructions.
- The generated page, navigation, signatures, links, and metadata were inspected rather than inferred from source rendering.
- Every affected HTML page and its same-source Markdown counterpart agree on
  the public contract, and discovery files point to the canonical version.
- Alternate links, Markdown routes, crawler metadata, and version isolation
  have build evidence when the change touches them.
- Model-targeted anti-patterns from the machine-readable surface section are
  absent.
- Only owned files changed and generated output is not staged.

A human reviewer should be able to answer “yes” to these questions:

1. Can a new reader identify the outcome and first useful step in under a minute?
2. Can an experienced reader find the public contract without reading a tutorial?
3. Would copying the example call real APIs with the shown argument shapes?
4. Are the return value, ownership, and important failure modes unambiguous?
5. Does the text distinguish model-directed delegation from application-directed workflow control?
6. Are Safety notes concrete, proportional, and paired with a useful action?
7. Does the generated site look intentional rather than merely compile?
8. Can a model reach the canonical Markdown without guessing or scraping HTML?
9. Do the curated and full-text discovery files describe one internally
   consistent release?

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
- `README.md` is the landing page. Guides appear in this order: Getting Started,
  Core Concepts, Models and Providers, Prompts as Views, Tools, Structured
  Results and Content, Compose Agents, Skills, Workspaces and Sandboxes, Code
  Mode, Integrations, and Running in Production. This contributor guideline
  does not appear in reader navigation.
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
