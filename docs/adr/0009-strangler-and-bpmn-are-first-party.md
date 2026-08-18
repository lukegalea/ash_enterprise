# ADR 0009 — `ash_strangler` and `ash_bpmn` are first-party platform extensions

- **Status:** proposed
- **Date:** 2026-08-18

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
deletion, never a refactor". Both of these are 0.1.0 and one is unpublished, so by the letter of the
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

**What remains before this ADR can be `accepted`** is no longer an authorization gap. It is the
composition itself: adding both packages to `mix.exs`, mapping one legacy table through
`ash_strangler` in this repository, and putting one approval behind `ash_bpmn` on a resource that uses
`AshEnterprise.Platform.Resource`. Until that exists, the claim being made here is a design decision
with the obstacles removed, not a demonstration.

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

**Dropping `ash_strangler`:** remove the dep, delete the twin resources and the `strangler` blocks
from any resource carrying one, and run `mix ash_strangler.gen.migration` in reverse to drop the
compatibility views and `INSTEAD OF` triggers **before** removing the code, or the legacy application
loses its write path. Order matters here in a way it does not elsewhere in this repository. Half a day
if no mapping has reached the dual-write phase; a planned cutover if one has.

**Reverting only this ADR** — keeping both packages standalone and not depending on them here — costs
nothing but the demo. The plans in `docs/plans/` would have their original scoping restored, and the
roadmap items in `docs/roadmap.json` would move from `partial` back to a separate-repository note.
