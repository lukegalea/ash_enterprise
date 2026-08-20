# ADR 0009 — `ash_strangler`, `ash_bpmn` and `ash_decisions` are first-party platform extensions

- **Status:** accepted
- **Date:** 2026-08-18 (accepted 2026-08-20; see [Amendment](#amendment-2026-08-20--the-composition-exists))

## Context

Two packages were designed in this repository's `docs/plans/` before either existed, and both were
scoped the same way. `docs/plans/ash-strangler.md` says it plainly:

> **Scope:** a *standalone open-source package*, living outside this repository. There is nothing to
> add to `mix.exs` here.

`docs/plans/business-process-modelling.md` is the same shape — a design for approvals and process
modelling, "fully planned, no code".

That scoping was correct when it was written, because neither package existed and a reference
application should not take a dependency on a document. It is no longer correct, because both were
built. Verified against the working trees on 2026-08-18:

**`ash_strangler` 0.1.0** — MIT, public at `github.com/lukegalea/ash_strangler`, not on Hex, and
currently on a feature branch rather than `main`. Maps a well-modelled Ash resource onto a legacy
PostgreSQL relation and moves it through four named phases — `:read_from_legacy`, `:dual_write`,
`:read_from_new`, `:decommissioned`. What is in `lib/` is not a sketch. 12.7k lines against **341
tests in 21 files**: a generated read-only *twin* resource built from `pg_attribute`/`pg_index`/
`pg_constraint`; a closed combinator grammar of ten mapping entities implementing the typed invertible
mappings of [ADR 0008](0008-typed-invertible-legacy-mappings.md), where each entity is a constructor
whose reverse is *built* rather than an expression something tries to invert; a proof-obligation engine
deciding round-trip laws by finite-domain enumeration and reporting counterexamples, re-emitting the
undecidable ones as SQL that `mix ash_strangler.check` runs against real legacy rows; **twelve
compile-time verifiers**; compatibility-view, reverse-view, `INSTEAD OF` trigger and `pg_notify` SQL
generation; a resumable backfill and a mutation-tested drift reconciler; and a column-level lineage
graph that already emits **OpenLineage** events (`lineage/open_lineage.ex`).

**`ash_bpmn` 0.1.0** — MIT, currently private at `github.com/lukegalea/ash_bpmn`, not on Hex, also on a
feature branch. Two layered products. Approvals as a domain: `changes/require_approval.ex` is an
`Ash.Resource.Change` dropped on any action, with a materialized candidate list, maker-checker
exclusion applied **by subtraction at candidate resolution rather than as a `forbid_if`**, delegation
with accountability, and remind/escalate/expire timers that are Oban jobs whose ids are stored on the
task so they actually get cancelled when it completes early. And processes as data: a BPMN XML document
compiled and verified into an immutable versioned graph snapshot, executed by a token interpreter — one
row per live branch, claimed optimistically — over Postgres and raw Oban, with an embedded bpmn-js
designer. 7.9k lines against **176 tests in 7 files**, against real Postgres.

Two things about `ash_bpmn` are worth naming here rather than in the integration ticket. It depends on
**raw `oban`, not `ash_oban`**, and on neither `ash_state_machine` nor `ash_events` — so it does not
compose with this repository's audit layer for free. And its resources are produced by `__using__`
macros rather than a Spark extension, which is the constraint the next section turns on.

So the question this ADR answers is no longer "should these be built" but **"what are they to this
repository?"** — and the honest answer changes the shape of the project.

## Decision

**`ash_strangler` and `ash_bpmn` are first-party extensions of the `ash_enterprise` platform, not
third-party packages that happen to share an author.** This repository depends on both, and the
combined system — not the platform layer alone — is what it demonstrates.

Three claims follow, in dependency order.

**1. The composition is the product.** Each package alone is a useful library. Together with the
platform layer they close a loop that neither closes alone:

| Layer | Answers | Package |
|---|---|---|
| The nouns | What are the entities, and what do they inherit? | `ash_enterprise` platform + CDM corpus |
| The on-ramp | How do those entities exist over the database you already have? | `ash_strangler` |
| The verbs | How do the processes people follow become declarative and auditable? | `ash_bpmn` |
| The rules | How do the decisions those processes route on change without a deploy? | `ash_decisions` |
| The surfaces | How does anyone use it? | derived — admin, JSON:API, GraphQL, A2UI, MCP |

The migration story and the process story are the same story told from opposite ends. A team
strangling a legacy application is migrating *data* out of a schema and *behaviour* out of procedural
code that encodes a process nobody wrote down. `ash_strangler` handles the first; the second is what
`ash_bpmn` is for. Doing only the first leaves you with a clean schema and the same untraceable
business logic.

**2. One authorization model underneath all of it.** This is the load-bearing claim, and it is the
reason the composition is worth more than the parts. A `ash_strangler` compatibility view is read
through ordinary Ash actions, so it is filtered by the same policies as everything else. A `ash_bpmn`
human task is an ordinary owned, tenant-scoped, audited record, so *who may approve* is a role grant
evaluated by the same pure union of grants as *who may read* — not a workflow engine's private ACL
table. That is why [ADR 0015](0015-approvals-stay-in-ash.md) refuses an external BPMN engine: the
engine is not the hard part, the second security model is.

**3. The tier rules still apply, with the reason restated.** [Thesis 6](../manifesto/06-reversibility.md)
puts alpha and unpublished packages in tier 3 — "isolated behind a seam; removing it must be a
deletion, never a refactor". All three are 0.1.0 and none is on Hex, so by the letter of the
rule they are tier 3. The letter is right and the reasoning behind it needs restating: tier 3 exists
because *someone else's* pre-1.0 package can be abandoned or can change under you. For a package we
write, the risk is different — not abandonment but scope creep — and the mitigation is different too.
So the rule is kept and its justification changed: `ash_bpmn` code stays confined to its own domain
and routes, and a `ash_strangler` mapping stays a block on a resource that can be deleted, **because
those exits are what let the reference application be right-sized by whoever clones it**, not because
we distrust the maintainer.

## Does it consume ActorContext?

**`ash_strangler`: yes, by construction.** It produces ordinary Ash resources over generated views,
read through the ordinary action layer, so `AshEnterprise.Security.ActorContext` filters them exactly
as it filters a hand-written resource. There is no second read path to secure.

**`ash_bpmn`: yes, since 2026-08-18 — and it took three fixes to get there.** This ADR was written
while it did not, and the findings are kept below because the remedies are the interesting part.

1. **It shipped no policies while running unauthorized internally.** Every generated resource declared
   `authorizers: [Ash.Policy.Authorizer]` and then contained no `policies do` block at all, while the
   engine passed `authorize?: false` at roughly ninety call sites across the facade, the advance
   worker, the timer worker and the LiveViews. Engine calls now carry `AshBpmn.Scope.engine/2` —
   actor, tenant, and a private context flag — and every generated resource declares one bypass on
   `AshBpmn.Checks.AshBpmnInteraction`.

   The honest framing, which that module states itself: this is **not** a stronger boundary than the
   option it replaced. Anything that can set private context could have passed `authorize?: false`.
   What changed is that the engine's authority is one named, greppable, testable thing in the policy
   set rather than ninety anonymous ones, so a host can read it, reason about it, and replace it. A
   test fails the build if a ninety-first appears; the one deliberate exception is
   `AshBpmn.Scope.subject/2`, which reads the *host's* subject record, over which no `ash_bpmn` policy
   has anything to say.

2. **Multitenancy was declared but not plumbed.** `AshBpmn.start_instance/2` accepted a `:tenant`
   option and discarded it, and no test exercised `tenant?: true` — the test tables had no
   `organization_id` at all, so nothing could have caught it. The tenant now reaches the instance, its
   tokens, its work items and its events, including the ones background workers create: it travels in
   the Oban payload, because a job outlives the process that enqueued it. A second, tenant-scoped copy
   of the tables exists purely so the suite can assert it, cross-tenant reads included.

3. **A work item can now sit on the platform base resource.** Every resource macro takes `:base` and
   `:base_opts`, so a human task inherits ownership, provenance, soft delete, the audit hook and this
   repository's policy set.

**One composition rule survives, and it is Ash's rather than anyone's oversight.** Policies fold into
a single boolean expression in which a bypass contributes a disjunct covering the policies *after* it
— so a bypass skips only what follows it. A base resource emits its policy set from `use`, ahead of
anything `ash_bpmn` adds, which means the engine's bypass lands second and does not fire. Adopting
`ash_bpmn` here therefore requires one of two things, and the choice belongs in the adoption commit
rather than here:

  * add `bypass AshBpmn.Checks.AshBpmnInteraction` at the top of
    [`AshEnterprise.Security.Policies`](../../lib/ash_enterprise/security/policies.ex), where the
    `SystemActor` bypass already sits — the engine then keeps the human actor, so ownership,
    provenance and the audit entry still name the person who approved; or
  * set `config :ash_bpmn, engine_actor: {AshEnterprise.Platform.SystemActor, :system, []}`, which
    needs no change to the policy set at all because it already bypasses on `SystemActor` — at the
    cost of attributing every engine write to that system actor, leaving the human only in
    `decided_by_id` and its siblings.

**What remained before this ADR could be `accepted`** was no longer an authorization gap. It was the
composition itself: adding both packages to `mix.exs`, mapping one legacy table through
`ash_strangler` in this repository, and putting one process behind `ash_bpmn` on a resource that uses
`AshEnterprise.Platform.Resource`. Until that existed, the claim being made here was a design decision
with the obstacles removed, not a demonstration. **It now exists — see the amendment below.**

## Amendment, 2026-08-20 — the composition exists

**Status moves from `proposed` to `accepted`, and the first-party set gains a third member.**

**What closed it.** All three packages are in `mix.exs` as `github:` dependencies. `ash_strangler`
supplies the read model over `legacy.*` plus the notification bridge. `ash_bpmn` and
`ash_decisions` instantiate eight resources under `AshEnterprise.Bpmn` and
`AshEnterprise.Decisions`, each on `AshEnterprise.Platform.Resource`. And an end-to-end process runs
in this application, started by an audit event rather than by a wired action: a request is submitted,
a trigger matches, a FEEL guard evaluates, a versioned DMN decision is invoked, its answer is
promoted onto the token, a gateway routes on it, and the process either grants the role through an
ordinary Ash action or parks on a human approval whose candidates exclude the requester. Asserted by
`test/ash_enterprise/process/access_request_demo_test.exs` and
`test/ash_enterprise/bpmn/adoption_test.exs`.

**The bypass choice was made, and it was the first of the two options above.** `AshBpmn.Checks.AshBpmnInteraction`
and `AshDecisions.Checks.AshDecisionsInteraction` are declared at the top of
[`AshEnterprise.Security.Policies`](../../lib/ash_enterprise/security/policies.ex), ahead of the
`SystemActor` bypass — following the precedent the `authentication?:` option already set for
prepending. So the engines keep the human actor, and ownership, provenance and the audit entry still
name the person who acted. `config :ash_bpmn, engine_actor:` was rejected for exactly the reason the
audit log exists. A test asserts both bypasses precede every other policy, on a generated *and* on a
hand-written platform resource, so a reordering fails the build.

**`ash_decisions` joins the set**, and the argument is the one made above rather than a new one: it is
a package we write, and its exit is that a decision is a DMN document nothing else in the application
parses. Its conformance measurement, its refusals and its known gaps are
[ADR 0028](0028-decisions-are-dmn.md); the language it shares with `ash_bpmn` is
[ADR 0027](0027-feel-is-the-expression-language.md); baselines and per-tenant bindings are
[ADR 0029](0029-process-configuration-is-tenant-data.md); and event-driven starts are
[ADR 0030](0030-events-trigger-processes.md).

**The lockstep named in Consequences below is now a diamond, and one corner is someone else's.**
`ash_bpmn` and `ash_decisions` both declare `boxic_feel ~> 0.2`, and `boxic_dmn` requires
`boxic_feel ~> 0.2.0` — so the tightest constraint is patch-level and belongs to a package we do not
release. One mitigation exists and one does not, and the gap is worth naming rather than blurring.

*Exists:* FEEL expression evaluation goes through **one adapter module per package** —
`AshBpmn.Feel` and `AshDecisions.Feel` — so a replacement is two modules rather than a sweep. CI here
also installs `libxml2-utils` explicitly rather than relying on the runner image carrying `xmllint`,
because the failure mode of assuming it is a suite that breaks the week the image is rebuilt with
nothing in this repository having changed.

*Does not exist:* **a CI job that builds all four repositories from their working trees.** That is the
only place the diamond is actually resolved, and today each repository's CI resolves its own
dependencies independently — so a `boxic_feel` release that satisfies one constraint and not the other
is discovered by a build failure somewhere else, which is precisely the maintenance obligation the
Consequences section below predicted. `ash_strangler` having been red on `main` for consecutive runs
is the precedent for why "green locally" is not evidence.

**A correction to what this ADR says about silent removal.** The body describes dropping `ash_bpmn`
as a *behavioural* change rather than a compile error, because an action losing
`AshBpmn.Changes.RequireApproval` simply takes effect. Dropping **`ash_decisions`** is the opposite,
and loudly so — but not for the reason first assumed. The interpreter does **not** raise on an
unknown node type; it returns `{:error, "unsupported node type: …"}` and the advance worker lets Oban
retry. What raises is narrower and better: `AshBpmn.Config.decision_resolver!/0` raises **naming the
config key** when no resolver is configured, `AshBpmn.Compiler.Verify` refuses at publish time with
the node id and the same key, and the interpreter raises on any resolver failure with the node id. So
a published `businessRuleTask` fails visibly with a message that says what is missing, which is the
opposite of the `RequireApproval` case and is worth stating because the two live in the same reversal
section.

**One further correction, to the JavaScript claim.** `ash_bpmn`'s repository is now **public**, so the
"currently private" note in Context is stale; `ash_decisions` declares the same remote. And the
`phoenix_live_view` runtime dependency named in Consequences below is joined by a real asset cost:
`bpmn-js` is a diagram editor with no server-rendered equivalent, and adopting it required dataurl
font loaders and an explicit `<link>` for the stylesheet esbuild emits alongside `app.js` — without
the second, the designer renders as unstyled boxes, which looks like a bad diagram rather than a
missing file. That roughly triples the JavaScript surface of a repository that had deliberately kept
it near zero, and it belongs in thesis 6's cost column rather than in a bundle report.

## Consequences

**What this makes easy.** The vision the repository markets becomes demonstrable end to end instead of
in three disconnected halves: point an agent at an existing application, adopt CDM nouns, derive the
enterprise schema, map it back onto the old rows, model the processes, and the surfaces are already
there. The `docs/plans/ash-strangler-in-reference-app.md` demo stops being optional — it is the proof.

**What this makes hard.** Three things get worse, and none of them is hypothetical:

- **The dependency graph widens.** `ash_bpmn` declares `phoenix_live_view ~> 1.0` as a *runtime*
  dependency, because the designer ships with it. That is harmless here — this is a Phoenix
  application — but it means a workflow engine drags a web framework into any consumer's tree. Worth
  a follow-up in the package (optional dependency, or split the designer out); not a blocker here.
- **Version lockstep becomes a maintenance obligation.** Three repositories that must agree is three
  repositories where a breaking change is discovered by a build failure somewhere else.
- **The "clone it and delete what you do not need" promise gets harder to keep.** A template with more
  moving parts is a template with more to delete, which is exactly what thesis 6 exists to guard.

**What it forecloses.** Adopting an external BPMN engine later means migrating live process instances
out of `ash_bpmn`'s token tables, which is materially harder than never having started. That trade is
argued in [ADR 0015](0015-approvals-stay-in-ash.md).

## Reversal

Cheaper than most decisions in this directory, because both packages sit at the edges rather than
under everything.

**Dropping `ash_bpmn`:** remove the dep from `mix.exs`, delete the BPMN domain module and its
resources, drop the designer/task-list routes from `lib/ash_enterprise_web/router.ex`, and generate a
migration dropping its six tables. Any action carrying `AshBpmn.Changes.RequireApproval` loses the
change and takes effect immediately — which is a behavioural change, not a compile error, so it needs
a deliberate review of each site rather than a `grep`-and-delete. Approximately a day, plus that
review. In-flight process instances are lost; there is no export.

**Dropping `ash_decisions`:** remove the dep, delete `lib/ash_enterprise/decisions.ex` and its two
resource instantiations, `lib/ash_enterprise/process/decision_resolver.ex`, the
`AshDecisionsInteraction` bypass and the `/app/decisions` routes; generate a migration dropping its
two tables. Then find every published process containing a `businessRuleTask` and edit it, because
those fail visibly rather than silently — see the correction in the amendment above. `libxml2` stops
being a runtime dependency, which is the one thing this reversal buys back. Roughly a day, plus the
diagram edits. Detailed in [ADR 0028](0028-decisions-are-dmn.md#reversal).

**Dropping `ash_strangler`:** remove the dep, delete the twin resources and the `strangler` blocks
from any resource carrying one, and run `mix ash_strangler.gen.migration` in reverse to drop the
compatibility views and `INSTEAD OF` triggers **before** removing the code, or the legacy application
loses its write path. Order matters here in a way it does not elsewhere in this repository. Half a day
if no mapping has reached the dual-write phase; a planned cutover if one has.

**Reverting only this ADR** — keeping both packages standalone and not depending on them here — costs
nothing but the demo. The plans in `docs/plans/` would have their original scoping restored, and the
roadmap items in `docs/roadmap.json` would move from `partial` back to a separate-repository note.
