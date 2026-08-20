# ADR 0015 — Approvals and process modelling stay inside Ash

- **Status:** proposed
- **Date:** 2026-08-18

## Context

[Thesis 7](../manifesto/07-what-we-do-not-have.md#3-approval-workflows--maker-checker) names this as
the third gap on the honest list, and describes the workaround it costs:

> There is no Ash extension for the single most requested enterprise workflow pattern: an action that
> requires a second person's approval before it takes effect, with delegation, escalation, and an audit
> trail of who approved what. … compose it. `ash_state_machine` for the approval lifecycle, policies for
> who may approve, `AshEvents` for the trail, and `Reactor` where an approval fans out into multiple
> downstream effects. This works, and it is genuinely more code than the rest of the security model
> combined.

`docs/plans/business-process-modelling.md` (955 lines) then reasoned the alternative out on paper and
recommended a token-based interpreter as an Ash domain driven by Oban — explicitly *not* a
BPMN-conformant engine and *not* a JVM integration. That recommendation has since been built as
`ash_bpmn`, which [ADR 0009](0009-strangler-and-bpmn-are-first-party.md) adopts as first-party.

This ADR records the decision that recommendation implies but never states: **not adopting an external
workflow engine.** The alternatives deserve to be written down and dated, because the usual reflex when
an enterprise architecture meets the word "approval" is to reach for Camunda, and the reasons not to
here are specific rather than aesthetic.

### What the alternatives actually cost, verified 2026-08-18

**Camunda is largely no longer the open-source option it is remembered as.** Camunda 7 was Apache-2.0,
and its **Community Edition reached end of life in October 2025** — no further releases and no security
patches. (Camunda 7 *Enterprise* support was extended to April 2030, which is a commercial product, not
an open one.) Since October 2024, all components of **Camunda 8 Self-Managed** — Zeebe, Operate,
Tasklist, Optimize, Identity — are released under **Camunda License 1.0**: source-available, free for
development and testing, and requiring a paid licence for production deployment. So "adopt Camunda" in
2026 means either a paid licence, a community fork such as CIB seven or Eximee, or a dead codebase.

**Flowable's core engines remain Apache-2.0** on GitHub, with advanced capabilities and support behind
a commercial edition — the ordinary open-core split. It is a genuine option and the strongest external
candidate.

**Zeebe/Temporal-style durable execution** is a different product answering a different question, and
this repository already answered the orchestration question in
[ADR 0004](0004-reactor-over-oban-pro.md): Reactor for in-request sagas, Oban for durability.

## Decision

**Approvals and process modelling are implemented inside the Ash action and policy layer, via
`ash_bpmn`. No external workflow or BPMN engine is adopted.**

The licensing situation above is real and is *not* the argument — Flowable would clear that bar. The
argument is structural, and it is the same one this repository makes about every other external tool.

**A workflow engine is not primarily an execution engine. It is a second identity, assignment and
authorization model.** Camunda and Flowable each carry their own notion of users, groups, candidate
groups, task ACLs, tenant ids and audit history. Adopting one means every question this repository has
already answered gets a second answer that must be kept synchronized with the first:

| Question | Answered here by | Answered again by an external engine |
|---|---|---|
| Who is this actor? | `ActorContext`, built once per request | the engine's identity service |
| Who may approve this? | a role grant, evaluated as a pure union | a candidate-group assignment |
| Whose tenant is this? | `organization_id`, inherited | the engine's tenant id |
| What happened, and when? | the central `AshEvents` log | the engine's process history tables |

Every row of that table is a synchronization job, and synchronization jobs diverge. The divergence is
also silent in the direction that matters: an engine whose group membership is stale grants approval
rights that the application would refuse.

**The sharpest version of the objection is about maker-checker specifically.** Every external engine
expresses "the requester may not approve their own request" as an exclusion evaluated at decision time
— a deny rule. This repository's second non-negotiable forbids exactly that shape:
[thesis 3](../manifesto/03-authorization-is-data.md) rests on the grant set being a pure union, and
`forbid_if` for row access reintroduces the order-dependence the whole model exists to remove.
`ash_bpmn` gets the same outcome without the deny rule: the candidate list is **materialized as rows**
when the task is created, and the exclusion is applied by **subtraction at candidate resolution**. The
requester is never a candidate, so nothing has to forbid them. That is not a stylistic preference; it
is the only formulation compatible with the authorization model this repository is built on, and no
external engine offers it.

The corresponding discipline, stated in `ash_bpmn`'s own usage rules, is the inverse guard: **the
process graph orchestrates and never decides.** Every node resolves to a host callback and every
mutation runs through an ordinary Ash action with its own policies and validations. Business logic in
the graph would be the controller-layer authorization mistake in a new costume.

## Does it consume ActorContext?

That is the whole point of the decision, and — as
[ADR 0009](0009-strangler-and-bpmn-are-first-party.md#does-it-consume-actorcontext) records in detail —
it is currently the design intent rather than the state of the code. `ash_bpmn` ships no policies while
passing `authorize?: false` internally, and discards the `:tenant` option it documents.

Being blunt about the consequence: **until those are fixed, this ADR's central claim is unproven.** An
approval that does not carry a tenant and is written through an unauthorized path is not "an ordinary
audited record", whatever the architecture diagram says. The three fixes named in ADR 0009 are the
acceptance criteria for both ADRs, and neither should move from `proposed` to `accepted` before a test
in this repository demonstrates that a user without the approval privilege cannot decide a task.

> **2026-08-20.** The three fixes landed on 2026-08-18 and the composition landed on 2026-08-20, so
> the first half of that paragraph is now history rather than a gap — a work item carries its tenant,
> sits on the platform base, and is written through a named bypass whose ordering a test enforces. The
> second half still stands: the negative test named above does not exist. See the amendment below for
> why that keeps this record `proposed` while ADR 0009 is `accepted`. One modelling correction found
> on the way is worth carrying here, because it bears directly on maker-checker: `HumanTask` was
> `:user_owned`, which requires a non-null `owner_id` — but **a task has no owner until someone claims
> it.** An open approval is unassigned on purpose; that is what makes it claimable by any of its
> candidates, and inventing an owner at creation would mean either the requester, whom maker-checker
> excludes, or an arbitrary candidate, to whom it does not yet belong. It is organization-owned, with
> `TaskCandidate` rows governing access — which is the mechanism
> [thesis 3](../manifesto/03-authorization-is-data.md) argues for rather than a workaround for it.

## Amendment, 2026-08-20 — DMN semantics without a DMN engine

The decision above has not changed. What has changed is that the argument now has a second instance,
and stating it makes the original sharper rather than merely longer.

`ash_decisions` ([ADR 0028](0028-decisions-are-dmn.md)) adopts **DMN as a modelling language and a
document format** — decision tables, literal expressions, DRDs with information requirements, hit
policies, and FEEL as the expression language ([ADR 0027](0027-feel-is-the-expression-language.md)) —
and adopts **no DMN platform.** There is no Camunda 8 decision engine, no Trisotech server, no
DMN-as-a-service. The same distinction this ADR draws for approvals, one layer down.

**It is the same argument, and the table above is the reason.** A hosted decision service carries its
own notion of who may author a rule, who may publish one, which tenant a decision belongs to, and
what its evaluation history is. Adopt one and every row of that table gets a second answer that has
to be kept synchronized with the first — except that a decision layer makes it worse than the
approvals case, because a *rule* is exactly the kind of thing a customer wants to edit and therefore
exactly the kind of thing that needs the authorization model the application already has. A decision
definition here is an ordinary owned, tenant-scoped, audited, policy-governed record; who may publish
one is a role grant evaluated by the same union of grants as who may read one; and its evaluation
history is a table in the same database as everything else it is evidence about.

**What this instance adds that the approvals argument did not have: a number.** The objection to
"we wrote our own" is that the standard is what makes the artifact portable, and a partial
implementation of a standard is a claim nobody can check. So the claim is checked. An independent
runner over the official DMN TCK, against the published engine, reports **3,414 of 3,495 asserted
result nodes — 97.68%**, with the 81 that fail listed individually and a gate that fails the build
when an unlisted one fails *or* when a listed one starts passing. That is a different kind of
statement from "not BPMN-conformant, and will not be", which is what this ADR says two sections up
about the process engine. **Where DMN semantics can be measured, they are; where BPMN conformance
cannot be claimed, it is not.** Both halves are the same policy: say which one you have.

**And the same discipline applies in the same words.** `ash_bpmn`'s rule is that *the process graph
orchestrates and never decides*. Its counterpart here is that **a decision decides, and never acts
and never authorizes.** A rule expressed in a decision table that *enforced* something would be
enforced in one place and bypassed by every other caller — the controller-layer authorization mistake
in a new costume, which is what [thesis 1](../manifesto/01-model-your-domain.md) exists to eliminate.
A business rule task routes on the answer; the mutation that follows is an ordinary Ash action with
its own policies and validations.

**Why this ADR is still `proposed`.** Its own acceptance criterion is specific: *"a test in this
repository demonstrates that a user without the approval privilege cannot decide a task."* The
composition now exists and is demonstrated end to end — [ADR 0009](0009-strangler-and-bpmn-are-first-party.md)
moved to `accepted` on the strength of it, and the demo does park a privileged request on a human
approval whose candidates exclude the requester. But the negative assertion this ADR asked for has
not been written. Until it is, the maker-checker-by-subtraction claim is demonstrated by construction
and not by a test that would fail if it regressed, which is this repository's own standard and is why
the status has not moved.

## Consequences

**What this makes easy.** Approvals become a dependency rather than a project: one change on an action,
and the work item, candidates, exclusion, delegation, timers and event log come with it. Who may approve
is a role grant like any other, so it is administered through the same UI, the same API and the same
audit trail as who may read — and it is one indexed query, because candidates are rows rather than a
policy evaluated per request per task.

**What this makes hard.** Four costs, none of them small:

- **We own a workflow engine.** Every BPMN element it does not support is our backlog. It deliberately
  refuses call activities, sub-processes, the full event taxonomy and compensation, at compile time
  with the element id in the error — which is the honest failure mode, and still a refusal.
- **BPMN conformance is not claimed and will not be reached.** A team that needs to exchange diagrams
  with a Camunda shop, or that has bought BPMN tooling, is not served.
- **Hiring and consulting assume Camunda.** "We wrote our own token interpreter" is a harder sentence
  in a procurement meeting than "we run Camunda", regardless of which is the better engineering answer.
- **No Cockpit, no Optimize.** The operational tooling around a mature engine is a decade of work that
  a viewer LiveView does not replace.

**What it forecloses.** Migrating to an external engine later means exporting live process instances
from a token table into that engine's format, which nothing supports. In practice the reversal below is
"drain, then switch", not "switch".

## Reversal

The exit is real but has a shape worth stating, because it is not symmetrical with the other ADRs here.

**Stop starting new instances first.** Remove `AshBpmn.Changes.RequireApproval` from each action —
these are individually greppable, and removing one means the action takes effect immediately rather
than failing to compile, so each site needs a deliberate decision rather than a bulk edit. Let in-flight
instances drain; there is no export path, and each pins its own definition version, so they finish
correctly while nothing new starts.

**Then remove the engine.** Drop the dependency, delete the BPMN domain and its six resources, drop the
designer, viewer and task-list routes, and generate a migration dropping `bpmn_definitions`,
`bpmn_instances`, `bpmn_tokens`, `bpmn_human_tasks`, `bpmn_task_candidates` and `bpmn_process_events`.
Roughly a day of work after the drain, which is the part that takes as long as the longest-running
process.

**Adopting Flowable instead** would mean re-answering the four questions in the table above — an
identity sync, a group-to-role mapping, a tenant mapping, and a decision about which audit trail is
authoritative. Estimate that at weeks rather than days, and note that the maker-checker formulation
would have to become a deny rule, which is a change to
[thesis 3](../manifesto/03-authorization-is-data.md) and not merely to a dependency. That is the real
cost of reversal, and it is why this decision is worth writing down now rather than later.
