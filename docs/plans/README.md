# Plans

Long-form specifications. A plan is written *before* the code because the design questions are cheap to
answer on paper and expensive to answer in an implementation — and because the findings in them hold
whether or not the thing is ever built.

| Plan | Status | What it specifies |
|---|---|---|
| [`ash-strangler.md`](ash-strangler.md) | **Built** — see [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) | Strangler-fig migration for Ash: mapping a well-modelled resource onto a legacy PostgreSQL schema and moving it through four cutover phases. |
| [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md) | **Partly built** | How *this* repository demonstrates the above, and the collisions that surfaces with the platform base resource. Steps 0-3 of §5 are built, plus the projection in the dated addendum; steps 4-8 are not, and the addendum is explicit that it is not progress along that sequence. |
| [`business-process-modelling.md`](business-process-modelling.md) | **Built** — see [ADR 0015](../adr/0015-approvals-stay-in-ash.md), plus [an appended correction](business-process-modelling.md#correction--2026-08-20) | Approvals as a domain, then processes as data. Recommends a token-based interpreter as an Ash domain driven by Oban, not a BPMN-conformant engine. |
| [`ash-bpmn-in-reference-app.md`](ash-bpmn-in-reference-app.md) | **Built** | How *this* repository runs a process started by an audited write, and the thirteen places the engine and the platform base resource disagreed. The companion to `ash-strangler-in-reference-app.md` for the other half of ADR 0009. |
| [`decisions-and-feel.md`](decisions-and-feel.md) | **Built**, with one named exception | Why FEEL replaced a bespoke expression language, why decisions are DMN in a first-party package, what is refused and why, and how the conformance number was measured — including the four ways its first run was false. |
| [`event-triggered-processes.md`](event-triggered-processes.md) | **Built** | How an audit event starts a process, and how a tenant diverges from a platform baseline without forking it forever. Includes the measurements behind the one guarantee the design rests on. |
| [`ash-api-versioning.md`](ash-api-versioning.md) | **Proposed** | One resource, one schema, N presentation contracts. Version deltas as data, with `render`/`parse` invertibility checked at compile time and no new database objects. |

## A note on the two that were built

`ash-strangler.md` and `business-process-modelling.md` were both written with a header saying
**DEFERRED, nothing here is built** and scoping the result as a standalone package outside this
repository. Both have since been built — as
[`ash_strangler`](https://github.com/lukegalea/ash_strangler) and `ash_bpmn` — and
[ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) adopts them as first-party extensions of
this platform. **Their headers are now out of date and the documents are not being rewritten to hide
it**, because the more useful record is what was predicted against what was found.

`ash-strangler.md` in particular is worth reading alongside `docs/HANDOFF.md` §5, which lists **seven
ways building it disproved the plan** — including that the load-bearing architectural decision in §6.1
turned out to be impossible. Every one was found by executing generated SQL rather than by rereading
the document, which is the lesson the plans exist to teach.

The same is likely true of `ash-api-versioning.md`. Its own §9 already concludes that the DSL sketched
in its commissioning brief cannot deliver the compile-time guarantee it promises, and proposes a closed
combinator grammar instead — a conclusion reached by working the design rather than by building it, and
one to re-test against an implementation.

## How a plan gets corrected, and the two that were written afterwards

`business-process-modelling.md` was the first to need correcting, and the convention it established is
the one to follow: **append a dated correction section; never edit the body.** Two of its positions were
settled differently by building it — §8's "one-way, DSL → diagram, always" and §10.7's open question
about where DMN sits — and the appended section says so, quoting what the original actually said. A
document silently brought into line with the code teaches nothing; the gap between the two *is* the
record.

`ash-bpmn-in-reference-app.md` and `decisions-and-feel.md` are the exception to the rule at the top of
this page. **Both were written after the code, not before**, and they should be read as design records
rather than as forecasts. That is a real weakness and worth naming: a plan written afterwards cannot be
wrong in the way the others can, so it cannot teach the thing this directory exists to teach. What it can
still do is state the limits honestly, which is why both carry an explicit list of what was designed and
not built.
