# Plans

Long-form specifications. A plan is written *before* the code because the design questions are cheap to
answer on paper and expensive to answer in an implementation — and because the findings in them hold
whether or not the thing is ever built.

| Plan | Status | What it specifies |
|---|---|---|
| [`ash-strangler.md`](ash-strangler.md) | **Built** — see [ADR 0009](../adr/0009-strangler-and-bpmn-are-first-party.md) | Strangler-fig migration for Ash: mapping a well-modelled resource onto a legacy PostgreSQL schema and moving it through four cutover phases. |
| [`ash-strangler-in-reference-app.md`](ash-strangler-in-reference-app.md) | **Deferred** | How *this* repository demonstrates the above, and the collisions that surfaces with the platform base resource. |
| [`business-process-modelling.md`](business-process-modelling.md) | **Built** — see [ADR 0015](../adr/0015-approvals-stay-in-ash.md) | Approvals as a domain, then processes as data. Recommends a token-based interpreter as an Ash domain driven by Oban, not a BPMN-conformant engine. |
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
