# ADR 0012 — OpenLineage as the schema, Marquez as the backend

- **Status:** proposed
- **Date:** 2026-08-18

## Context

Once data arrives from outside (ADR 0010), the question an auditor asks is not "what tables exist" but **"how
did this row get here, and what did it come from."** That is lineage, and it is a different question from
cataloguing (ADR 0013), which the two are routinely conflated.

The important structural fact is that **OpenLineage is a standard, not a product** — a vendor-neutral event
schema, in the same relationship to lineage tools that OpenTelemetry has to tracing backends. Choosing it is
therefore a much smaller commitment than choosing any tool that consumes it, and the two decisions should be
separated deliberately rather than bundled.

### Verified 2026-08-18

**OpenLineage.** Apache-2.0. LF AI & Data Foundation, **Graduated** — *the foundation's project page prose and
its own dated blog posts disagree on the month and on the sandbox/incubation naming, so the stage is confirmed
and the date is not.* Latest release v1.52.0, 2026-07-23; spec `$id` reports version **2-0-2** (*no dated
release entry for that spec version could be found*). The model is `Job`, `Run`, `Dataset`, with `RunEvent`
carrying `eventType` in `START | RUNNING | COMPLETE | ABORT | FAIL | OTHER`; `DatasetEvent` and `JobEvent`
exist as first-class schema definitions built on `BaseEvent`. The `columnLineage` dataset facet exists. The
`parent` run facet exists and gained a `root` field in v1.52.0. Native producers include Airflow, Spark, Flink,
Hive, dbt, Great Expectations, Trino; consumers include Marquez, DataHub, Atlan, Collate, Collibra, Egeria and
Amundsen. HTTP transport is a `POST` of JSON to `<base_url>/api/v1/lineage`.

**The three candidate backends.**

| | Marquez | DataHub | OpenMetadata |
|---|---|---|---|
| Licence | Apache-2.0 | Apache-2.0 | Apache-2.0 |
| Backing services | **PostgreSQL 14 + Java 17. No Kafka, no Elasticsearch.** | Kafka + OpenSearch + MySQL, all unconditional in the quickstart profile | Postgres ≥15 (or MySQL ≥8.0.42) **plus** Elasticsearch ≥9.0 or OpenSearch ≥3.0, required |
| OpenLineage ingest | reference implementation | **native HTTP**: `POST /openapi/openlineage/api/v1/lineage` | **Kafka or Kinesis consumer only — no HTTP endpoint** |
| Also a catalogue | no | yes | yes (ADR 0013) |

Two of those cells overturn assumptions worth stating outright, because both point the opposite way to
intuition.

**Marquez is close to dormant.** Its last formal GitHub release is **0.50.0, 2024-10-24**. Tags 0.51.0 and
0.51.1 exist (2025-03-25 and 2025-03-27) and were never cut as releases. There have been **24 commits since
2025-01-01**, with an eleven-and-a-half-month gap between March 2025 and March 2026, a five-commit burst in
March–April 2026, and **nothing since 2026-04-12** — four months as of today. Its README says "LF AI & Data
Foundation Graduated project under active development"; the README and the commit log disagree, and the commit
log is the one to believe.

**OpenMetadata cannot be used as a drop-in OpenLineage receiver.** Its OpenLineage connector "consumes
OpenLineage events from either a Kafka broker or AWS Kinesis Data Streams" — confirmed in the connector source
(`confluent_kafka.Consumer`, Kinesis via botocore, no HTTP handler). A producer using the standard HTTP
transport cannot be pointed at it; a third-party bridge project exists precisely because there is no native
HTTP path. DataHub is the one with the HTTP endpoint. OpenMetadata is also **not listed** among consumers on
openlineage.io.

### What this repository already has

`lib/ash_enterprise/platform/correlation.ex` threads a correlation id **and a `depth` counter** through every
action, and `lib/ash_enterprise/platform/changes/stamp_correlation.ex` stamps it onto every audit event via the
base resource. Both are already consumed twice — by `AshEnterprise.Audit.EventLog` and by the OpenTelemetry
tracer. The `depth` counter, borrowed from Dataverse's `plugintracelog`, exists so nested action invocations
can be told apart from sibling ones.

That is the same information a lineage graph needs, and it is already being produced.

**And the emitter is not speculative: it exists in the family already.** `ash_strangler`
([ADR 0009](0009-strangler-and-bpmn-are-first-party.md)) ships `lib/ash_strangler/lineage/open_lineage.ex`,
which renders its column-level mapping graph as an OpenLineage `columnLineage` facet. That is a narrower
problem than this one — a static graph of which legacy columns feed which attribute, emitted once, rather than
a run event per action — but it settles the two questions that usually sink an integration like this: the
schema is expressible from Ash's own metadata, and someone has already written the serialization against a
real OpenLineage consumer rather than against the specification.

The generalization this ADR proposes is therefore *dataset-and-run* lineage over the same standard the strangler
already emits *column* lineage into. If both land, the two halves compose into one graph — which legacy column
fed which attribute, and which action wrote it, when, in which transaction — without either half knowing about
the other. Neither is required for the other to be useful, which is the property worth having.

## Decision

**OpenLineage is the commitment. The backend is not. Marquez first.**

`ash_open_lineage` is an `Ash.Notifier` — no new instrumentation, no crawler, no second pass over the data. It
emits `RunEvent`s from action notifications:

| OpenLineage | Source here |
|---|---|
| `Run.runId` | `AshEnterprise.Platform.Correlation.id/0` — the same id already in the audit log |
| `parent` run facet | derived from `Correlation.depth/0`, which is what the counter was for |
| `Job.namespace` / `Job.name` | the domain, and `{resource}.{action}` |
| `Dataset` | the resource's Postgres table |
| `eventType` | `START` on notification dispatch, `COMPLETE` or `FAIL` on outcome |

**Lineage is therefore a second consumer of telemetry the platform already generates**, not a system to
maintain. That is [the manifesto's central claim](../manifesto/00-index.md) — declare it once, derive it
everywhere — applied to a concern that is usually bolted on. It is also why Marquez being nearly dormant is
survivable: the durable artifact is a schema with eight consumers, and the backend is deliberately the
disposable half.

Marquez is chosen over DataHub on operational floor (one Postgres against Kafka plus OpenSearch plus MySQL) and
over OpenMetadata on fit — the need here is traceability, and OpenMetadata's answer to lineage is a Kafka
consumer for a catalogue product, which is ADR 0013's problem and not this one.

## Does it consume ActorContext?

**The notifier does, structurally. Marquez does not consume anything — it has no authorization model at all.**

The notifier runs *inside* the action, after authorization has been decided. It only ever observes effects the
actor was permitted to cause. That is the correct direction and it is worth naming: lineage is emitted from
authorized effects, never recovered by a privileged crawl over the database. A crawler would need superuser
access and would report on rows no actor could see, which is a second view of the data with none of the policy
model attached.

Marquez has no users, no roles and no authentication. Anyone who can reach its API reads the entire graph. That
is not "a second copy of the security model to keep synchronized" — it is *no* copy, which is worse, and it
forces two rules.

**First: the lineage graph is metadata, and metadata leaks.** A dataset name plus a `columnLineage` facet
describes the shape of every tenant's data even when no row is exposed. Marquez is therefore deployed the way
`clarity` is deployed (see [thesis 6](../manifesto/06-reversibility.md)) — reachable from the internal network
only, never behind a public login, and never as a product surface.

**Second: no value, actor or tenant may appear in a facet.** Resource and table-level names only; never a
filter value, never an actor id, never an `organization_id`. **There is no verifier for this**, so it is a
review obligation rather than a structural guarantee — which is a genuine weakness of this design and the
thing most likely to go wrong quietly.

## Consequences

**Made easy.** Close to free, because the correlation id, the depth counter and the notifier hook all exist.
The lineage `runId` and the audit log's `metadata["correlation_id"]` are the same value, so "show me the
lineage for this audit entry" is a lookup rather than a join across two vocabularies. Vendor neutrality is
real: eight consumers speak the schema.

**Made hard, and these are the costs.**

*Marquez's maintenance status is the largest.* Releases stalled in October 2024 and commits stopped in April
2026. This is accepted on the explicit basis that the exit is cheap (below), and it should be re-examined
before anything is built rather than treated as settled by this ADR.

*No OpenTelemetry trace-context facet exists.* Issue #4588, "W3C trace context propagation", was opened
2026-06-01 and is still open and unmerged. So carrying our correlation id in a form other tools understand is
not possible today; a custom facet with our own `_producer` and `_schemaURL` round-trips as opaque JSON that no
consumer interprets. Adequate for our own queries, useless for cross-tool correlation — and worth re-checking,
because it is the one gap that would close on its own.

*No Elixir OpenLineage client exists.* A hex.pm search for `openlineage` returns zero packages
(*a negative result, not proof of nonexistence*). The transport is a JSON `POST`, so this is `Req` plus
structs — but **spec conformance becomes hand-maintained**, and spec 2-0-2 will move.

*The ingestion step is not covered*, and this is the sharpest problem. Per ADR 0010, neither Meltano nor
Airbyte emits OpenLineage, so the graph describes what happens *inside* this application and stops dead at the
staging schema boundary — exactly where the interesting provenance question starts. [ADR 0008](0008-typed-invertible-legacy-mappings.md)
argues that a diagram omitting edges it could not work out is worse than no diagram, "because a reader cannot
tell 'nothing feeds this' from 'the generator gave up'." That argument applies here unchanged. The mitigation
is to emit the ingestion `Job` event from the wrapper that invokes the pipeline; the discipline is to **emit
nothing rather than a graph with a hole at the point data enters.**

**Foreclosed.** Nothing meaningful. The schema is neutral and the backend is one config value.

## Reversal

Unusually cheap, and cheaper in one direction than expected.

**Marquez → DataHub:** change the transport base URL. DataHub exposes a native HTTP OpenLineage endpoint at
`POST /openapi/openlineage/api/v1/lineage`, so the emitted events need no change at all. The cost is
operational, not code: Kafka, OpenSearch and MySQL instead of one Postgres. **Minutes of code, a day of
infrastructure.**

**Marquez → OpenMetadata:** *not* a base-URL change, contrary to the obvious assumption. OpenMetadata consumes
OpenLineage from Kafka or Kinesis only, so this needs a Kafka broker plus a transport change from HTTP to
Kafka, or the third-party HTTP-to-Kafka bridge. Several days, and it introduces a broker this architecture
otherwise has no use for. Recorded here specifically because the intuitive assumption runs the other way, and
because ADR 0013's choice of OpenMetadata makes this the pairing somebody will reach for.

**To abandon OpenLineage entirely:** delete `lib/ash_enterprise/lineage/`, remove the notifier from
`AshEnterprise.Platform.Resource`, drop one config block. Nothing imports it — the notifier reads
`Correlation` and `Correlation` does not know it exists. Under an hour, and the audit log is unaffected because
it was never downstream of any of this.
