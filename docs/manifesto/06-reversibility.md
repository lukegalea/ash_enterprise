# Thesis 6 — Reversibility

> Every alpha, unpublished, or commercial dependency is isolated behind a named seam, with the exit documented.

## Why a reference architecture has to say this out loud

A template's job is to make good defaults easy. Its failure mode is to make bad defaults *permanent* — because the
person who cloned it in year one is not the person discovering in year three that a core dependency was abandoned, is
now paid, or never reached 1.0.

Ash's ecosystem is unusually healthy, but it is not uniform. Some packages are load-bearing infrastructure with millions
of downloads. Others are one maintainer's good idea from eight months ago. Depending on both is fine. Depending on both
*the same way* is not.

So every dependency here is placed in one of three tiers, and the tier determines how much of the codebase is allowed
to know about it.

## The tiers

**Tier 1 — bet on it.** Stable, widely deployed, core-team maintained. Used directly and idiomatically throughout,
with no abstraction layer. Wrapping these would be pure cost.

`ash` · `ash_postgres` · `ash_phoenix` · `ash_json_api` · `ash_graphql` · `ash_authentication` ·
`ash_authentication_phoenix` · `ash_admin` · `ash_oban` · `ash_archival` · `ash_paper_trail` · `reactor` · `igniter` ·
`spark` · `usage_rules` · `phoenix` · `oban`

**Tier 2 — production-viable, watch the version.** Real and useful, but younger or thinner than tier 1. Used directly,
but the version is pinned tightly and the ADRs name what we would do without them.

`ash_ai` · `ash_events` · `ash_state_machine` · `ash_money` · `ash_rate_limiter` · `ash_cloak` · `cinder` ·
`opentelemetry_ash` · `ash_credo` · `ash_ops`

**Tier 3 — isolated behind a seam.** Alpha, unpublished, unmaintained, or commercial. Confined to one directory or one
route. Removing any of these must be a deletion, never a refactor.

`ash_a2ui` (unpublished, git dep) · `clarity` (self-described alpha) · `ash_diagram` · `ash_strangler` (0.1.0,
first-party, not on hex) · `ash_bpmn` (0.1.0, first-party, not on hex) · `ash_decisions` (0.1.0, first-party, not on
hex) · `boxic_dmn` / `boxic_feel` (0.x, Apache-2.0, one author) · everything commercial

The rule that makes the tiers real: **tier 3 code may not be imported by tier 1 or tier 2 code.** Dependencies point one
way. A resource never knows that `ash_a2ui` exists.

`ash_strangler` is the one entry that does not satisfy that rule as stated, because a mapping is a block *on* a
resource. It is kept in tier 3 anyway, on the weaker property the rule exists to guarantee: the block is deletable
without touching anything around it. That is a real exception rather than a reading of the rule, and it is argued in
the seam below.

## The seams, specifically

### `ash_a2ui` — unpublished, pre-1.0

The declarative-UI layer is not on hex; it is a git dependency pinned to a SHA, with no example applications and an API
its own README says may change.

That is an acceptable risk *only* because of where it sits. A2UI surfaces live in `lib/ash_enterprise_web/a2ui/`, use
`AshA2ui.Standalone`, and are **separate modules from the resources they describe**. This is why the plan rejected the
alternative of putting `a2ui do ... end` blocks inside resource files: inline UI metadata would have made the domain
layer depend on a pre-1.0 package, and removing it would mean editing every resource.

The exit: delete `lib/ash_enterprise_web/a2ui/`, drop the routes. Every screen it renders has an `ash_admin` equivalent
already, so the application keeps working while a replacement is built.

### `clarity` — alpha, and it maps your whole domain

Clarity is genuinely excellent — navigable ER, class, and policy diagrams derived from live introspection — and its
README says, verbatim, that it is in an alpha state where things may break.

It is mounted **in `:dev` only**. Nothing at runtime depends on it, no module imports it, and it renders a complete map
of the domain model, which is not something to expose in production even behind a login. The exit is deleting one router
line.

### `ash_strangler`, `ash_bpmn` and `ash_decisions` — first-party, and still tier 3

All three are 0.1.0 and none is on hex, so by the letter of the rule they are tier 3. They are
also written here rather than found — [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) makes them
first-party extensions of the platform — which changes the *reason* for the placement rather than the placement.

Tier 3 exists because *someone else's* pre-1.0 package can be abandoned, or can change under you. For a package we
write, abandonment is not the risk; scope creep is. So the rule is kept and its justification restated: the exits stay
open not because we distrust the maintainer, but because they are what lets whoever clones this repository right-size
it. A template with more moving parts is a template with more to delete.

The seams are narrower than a directory. An `ash_strangler` mapping is a `strangler` block on a resource, so removing it
is deleting a block rather than refactoring the resource around it — with one ordering constraint that applies nowhere
else here: the generated compatibility views and `INSTEAD OF` triggers have to be dropped **before** the code, or the
legacy application loses its write path. `ash_bpmn` and `ash_decisions` are confined to their own domains
(`AshEnterprise.Bpmn`, `AshEnterprise.Decisions`, `AshEnterprise.Process`), one `live_session`, seven routes and two
LiveView directories. Dropping `ash_bpmn` also removes the approval change from any action carrying it, which takes effect
silently rather than as a compile error, so that part is a review rather than a `grep`. Both reversals are costed in
[ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) rather than repeated here.

**Dropping `ash_decisions` while keeping `ash_bpmn` fails loudly**, which is worth recording because it is the opposite
of the approval case and it happened by accident of how the interpreter is written rather than by design: a published
process containing a `businessRuleTask` becomes unexecutable, the interpreter raises on the unknown node type, and the
instance fails. A loud failure is the better one; that it is loud is luck.

**The lockstep is a diamond, and one corner is not ours.** `ash_bpmn` and `ash_decisions` must agree on a `boxic_feel`
version, and its release cadence belongs to someone else. What makes that survivable is that the engine is called from
**one adapter module per package** (`AshBpmn.Feel`, `AshDecisions.Feel`). What does *not* yet exist is the CI job the
design called for: **nothing here builds all four repositories from their working trees together.** CI resolves the
diamond only at the git SHAs `mix.lock` pins, and the four-way agreement is currently checked by hand — a clean re-fetch
of the git dependencies rather than a local path, which is the practice but not the gate. `ash_strangler` being red on
`main` for four consecutive runs is the precedent for why "green locally" is not evidence, and it applies to this too.

### The cost that is easy to leave out: the JavaScript surface

This repository has deliberately kept its JavaScript near zero, and the process and decision designers are the largest
single exception to that in its history. Stated in numbers rather than adjectives:

| | Before | After |
|---|---|---|
| Direct dependencies in `assets/package.json` | 5 (all A2UI/lit) | **7** — adds `bpmn-js ^18`, `dmn-js ^17.10` |
| Packages in `assets/package-lock.json` | 25 | **88** |
| `assets/node_modules` | — | **86 MB**, of which bpmn-js is 6.8 and dmn-js 7.5 |
| Hand-written JavaScript in `assets/js/` | 159 lines | **165 lines** — three hook imports and a registration |

So the *authored* surface did not move at all and the *installed* surface roughly tripled. That is the cost, and it is
worth restating that the numbers are the argument rather than the adjectives: two libraries bought 63 additional
packages and 86 MB of `node_modules`, on a repository whose whole client story was previously five A2UI packages and a
hundred and fifty lines, and whose authored JavaScript grew by six of them.

**What it buys is now both halves of the authoring story**, which is the thing that makes the trade defensible: bpmn-js
for processes and dmn-js for decisions, both imported by `assets/js/app.js`, both registered as LiveView hooks, both
scanned by Tailwind through an explicit `@source "../../deps/ash_decisions/lib"` — because `source(none)` means nothing
is scanned unless it is named, and forgetting it renders a working editor as unstyled boxes. Neither is a library with
a server-rendered equivalent; a decision table is a spreadsheet and a DRD is a graph, and hand-rolling either would be
more JavaScript than importing both.

**One thing it does not buy, and the residue is real.** `@bpmn-io/feel-editor` and `@bpmn-io/lezer-feel` arrive
transitively with dmn-js and are **unused**: there is no FEEL editor here, so the most error-prone text in a decision
table — a literal expression, a unary test — is typed into a plain input with no highlighting and no completion. That
subtree is a supply-chain surface already paid for and not yet drawn on, and the honest options are to wire it or to
stop counting it as free.

Three build details are load-bearing rather than tidy, and all three belong in an exit plan because they are what a
removal would have to undo: `NODE_PATH` must include `assets/node_modules` or esbuild cannot resolve `bpmn-js` from a
hook living in `deps/`; the icon font needs `dataurl` loaders or the build stops outright on an unresolved `.woff`; and
each package's `lib` needs its own `@source` line in `assets/css/app.css`.

**The licences are not symmetric, and one of them constrains the documentation pipeline.** `bpmn-js` and `dmn-js` both
carry the bpmn.io licence — MIT plus one clause: the source displaying the "Powered by bpmn.io" attribution must not be
changed, and the attribution must stay **fully visible and not visually overlapped**. Two consequences. Tailwind
preflight and the design system must not collapse `.bjs-powered-by` or its dmn-js equivalent. And **screenshot cropping
must not cut it off** — a real hazard, because the capture crops to the designer root; the script waits on
`.bjs-powered-by` as its readiness signal precisely because it is both the proof the editor booted and the thing the
licence requires, though a missing selector currently only warns rather than failing the run. Adding dmn-js doubles the
surface of the procurement conversation that
[`docs/plans/business-process-modelling.md`](../plans/business-process-modelling.md) §8 already flagged.
`@bpmn-io/feel-editor` — the FEEL authoring editor with autocompletion — is plain **MIT** and carries no such clause,
which is a point in favour of wiring it and is currently moot, since it is present only as an unused transitive
dependency.

### The decision engine — someone else's 0.x, behind one module

`boxic_dmn` 0.3.0 and `boxic_feel` 0.2.0 are the only third-party 0.x packages here on which a correctness property
depends: they *are* the DMN and FEEL semantics, for gateway conditions as well as decision tables. They are also
**Apache-2.0 rather than MIT**, which is compatible with everything here and carries obligations MIT does not — licence
text and attribution travelling with distributions, and an express patent grant with a termination clause. One precise
note, because the loose version of it is wrong: neither package ships a `NOTICE` file, so Apache-2.0 §4(d) has nothing
here to propagate. `ash_decisions` itself is MIT; the Apache terms attach to the engine underneath it.

The seam is unusually narrow and the exit is unusually well instrumented, which is the whole argument for accepting the
tier:

1. **One module per package calls the engine.** A replacement is two modules, not a sweep. `ash_bpmn` and
   `ash_decisions` each fail their own build if a second caller appears.
2. **The conformance suite is ours.** The official DMN TCK corpus is vendored here at a pinned commit with a hash
   guard, and the runner and expected-failure list are ours rather than upstream's. So a candidate replacement can be
   *measured* against the same 3,495 assertions before anything switches, which turns "find another engine" into a
   bounded piece of work with a number attached.

Both properties are load-bearing. Without them this dependency would not clear the bar the rest of this page sets, and
that is the honest way to state it rather than as a feature of the package.

Two costs it imposes on the deployment, neither reversible by deleting code. **`libxml2` is now a runtime dependency**:
the engine validates DMN documents against the normative XSD by shelling out to `xmllint`, so `devenv.nix`, CI and the
`Dockerfile`'s runtime stage all carry it, and without the binary every model fails to load. And **both packages declare
`elixir: "~> 1.20.0"`** while this repository pins Elixir 1.18.4 on OTP 27 to match what the Ash ecosystem is tested
against — they compile and pass here, and depending on a package whose stated constraint we violate is still not a thing
to do silently.

The limits of the decision layer itself — the overlap analysis that was designed and not built, and what an
`Evaluation` row cannot say — are [thesis 7 §3](07-what-we-do-not-have.md#3-approval-workflows--maker-checker), not
here. This page is about what it would cost to leave; that one is about what it does not yet do.

### The commercial options we did not take

Open-source-only was a requirement, and it is worth recording that it cost less than expected — and where it did cost
something:

| Commercial option | What we use | What we give up |
|---|---|---|
| **Oban Pro** — durable Workflows, Smart Engine, `await_signal/1` | `Reactor` 1.0 + plain Oban | The strongest case on this list, and stronger than first written. Reactor's saga orchestration is in-process and cannot durably park a process — verified against v1.0.6, where halting a pending inline step breaks on the next deploy and `{:halt, _}` checkpoints rather than parks (ADR 0004). **Oban Pro 1.7 (April 2026) shipped `await_signal/1`**: durable wait-for-human-approval with a deadline, holding no connection — exactly the primitive Reactor lacks. It is no longer the answer to the approval-workflow gap — `ash_bpmn` parks a token in a Postgres row and closed that gap without it ([thesis 7 §3](07-what-we-do-not-have.md#3-approval-workflows--maker-checker)) — which weakens this row rather than removing it: `await_signal/1` is still the better primitive for a *Reactor* that has to wait. The seam: orchestration lives in Reactor modules, which Pro workflows could replace one at a time. |
| **Oban Web** — job dashboard | `ash_admin` over the Oban tables + LiveDashboard | A real loss. Job introspection is meaningfully worse. |
| **Fluxon UI** — dense form components | daisyUI 5 + SaladUI 1.0 | Autocomplete, date-range and tags inputs are better in Fluxon. But Fluxon is a closed hex package, so **Claude cannot read or modify its source** — a material cost in an agent-driven codebase, and the reason this was not a close call. |
| **AppSignal** — turnkey APM | OpenTelemetry + `opentelemetry_ash` | `ash_appsignal` is more polished than `opentelemetry_ash` (0.1.x, thin). OTel keeps us vendor-neutral; expect to write more collector configuration. |
| **Tidewave Web** — in-browser agent | Tidewave MCP (free, Apache-2.0) | Only the paid tier's browser automation. The MCP server — the part that matters — is free. |

Each is a swap-in, not a rewrite, because each is confined: orchestration to Reactor modules, components to the web
layer, telemetry to one tracer module and one config block.

## The fourth category: services behind a network boundary

The three tiers rank *Elixir dependencies* by how much of the codebase may know about them. Most of
[the roadmap](../ROADMAP.md) is not a `mix.exs` entry at all. Meltano, Marquez, OpenMetadata, Superset and Nango are
processes on the far side of a network boundary, and "which modules may import it" is not a question you can ask about a
process. They get their own category, and two rules:

1. **The service consumes `AshEnterprise.Security.ActorContext`, or views derived from it.** It never owns a second copy
   of the authorization model. A service with its own RBAC, its own tenancy or its own audit trail is a second security
   model to keep synchronized, and every synchronization diverges eventually — silently, and in the permissive
   direction.
2. **Removing it degrades a feature; it never breaks the application.** Marquez going down should cost you lineage, not
   writes.

That is a stricter bar than "does an open-source project exist for this", and it disqualified two products that win on
features:

- **Metabase** — row-level security is behind the paid tier even when self-hosted, so adopting it would put
  [thesis 3](03-authorization-is-data.md) behind a paywall. → [ADR 0014](../adr/0014-superset-over-metabase.md)
- **Camunda / Flowable** — not a licensing objection. A workflow engine is a second identity, assignment and
  authorization model, and it expresses maker-checker as a deny rule, which this repository forbids outright. →
  [ADR 0015](../adr/0015-approvals-stay-in-ash.md)

One case does not fit comfortably, and stating it is more useful than smoothing it. **OpenMetadata's own RBAC resolves
Allow/Deny effects with deny winning** — the exact inverse of [thesis 3](03-authorization-is-data.md)'s pure union, and
precedence-dependent by construction. [ADR 0013](../adr/0013-openmetadata-as-catalog.md) therefore makes no attempt to
mirror role grants into it, and pays the price rule 1 implies: the catalogue is an internal tool for stewards and
auditors, and can never face tenants. Failing rule 1 does not always mean rejecting the tool. It means the feature it
would have supported is what the failure costs.

## The general rule

Before adding a dependency, answer two questions in the ADR:

1. **What breaks if this is abandoned tomorrow?**
2. **Is the answer confined to a directory I can delete?**

If the second answer is no, the dependency needs a seam before it needs a version number.

This is not a prediction that these packages will fail. Most will not. It is an acknowledgment that a template is copied
by people who will not read its git history, and that the cost of a seam is paid once while the cost of entanglement is
paid forever.

## Further reading

- `docs/adr/` — the per-decision record
- [thesis 7](07-what-we-do-not-have.md) — the gaps no dependency currently fills
- [`../ROADMAP.md`](../ROADMAP.md) — the external services, sequenced, and the one rule they were selected against
