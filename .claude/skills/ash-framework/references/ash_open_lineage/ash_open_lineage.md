# Usage Rules — ash_open_lineage

<!-- SPDX-FileCopyrightText: 2026 Luke Galea -->
<!-- SPDX-License-Identifier: MIT -->

Rules for hosts integrating this library. Generated-for-humans; keep this file
next to the README when feeding an agent or LLM.

## ALWAYS

- **Add the dep, then the extension per resource.**
  `{:ash_open_lineage, github: "lukegalea/ash_open_lineage"}` and
  `extensions: [AshOpenLineage.Extension]` with a `lineage do transport ... end`
  section on every resource whose provenance matters. The notifier installs
  itself — never also list `AshOpenLineage.Notifier` under `notifiers:`.
- **Configure the correlation provider.**
  `config :ash_open_lineage, correlation_provider: MyApp.Correlation` — the
  notifier derives each runId from the host's correlation id and the job
  (`sha256(correlation/namespace/job)`, formatted UUID-shaped: one run per
  correlation and job), and carries the correlation id itself in the
  `ashOpenLineageProducer` facet as `correlationId`, alongside `depth`. That
  facet field joins the graph to the audit trail only when the provider
  returns a stable id for the whole operation (per request). Without one the
  default mints a fresh UUID per call: throwaway ids that join nothing.
- **Configure the transport before first use.**
  Resources: per-resource `transport` in the `lineage` section.
  `emit/2`/`fail/3`: `config :ash_open_lineage, transport: ...` (default
  `Req`, which needs `config :ash_open_lineage, http_base_url: "http://localhost:5000"`).
- **Set `producer` and `emit_on` deliberately.** The `lineage` section also
  takes `producer` (the URI in each event's `producer` and facets' `_producer`;
  defaults to this library's GitHub URL, so set it to your application's) and
  `emit_on` (action types that emit; default `[:create, :update, :destroy]`).
- **Know when notifications dispatch.** On **ash ≥ 3.34** they fire
  automatically after every successful action, so extended resources emit
  without extra call-site ceremony. On earlier 3.x, Ash requires the per-call
  opt-in: `Ash.create!(changeset, notify?: true)`. Either way the notifier only
  sees successful, authorized actions.
- **Fill the holes.** Any data movement that does not go through a resource
  action (a Meltano/Singer tap wrapper, a nightly brief) MUST emit
  `AshOpenLineage.emit(job, event_type: :start, run_id: id)` before and
  `emit(job, event_type: :complete, run_id: id)` / `fail(job, reason, run_id: id)`
  after. A missing node is a lie of omission; pass the same `run_id` so the
  three events form one run. An explicit `run_id` is used verbatim; without
  one, `emit/2`/`fail/3` take the correlation provider's `id/0` as is (no
  per-job derivation, and no `correlationId` or `depth` in the facet unless
  passed as `:correlation_id` / `:correlation_depth`). To give a host job
  its own stable run inside a correlation, the way resource jobs get one,
  pass `run_id: AshOpenLineage.run_id(correlation_id, namespace, job_name)`.
- **Use `send/2` when a transport needs host context.** A transport that
  stores events in the host's database, scoped by tenant, implements the
  optional `send(event, meta)` callback. The notifier passes
  `%{tenant: tenant_or_nil, resource: resource, action: action_name}`;
  `emit/2`/`fail/3` pass their `:meta` option (a map, default `%{}`).
  Transports with only `send/1` keep working and never see `meta`.

## NEVER

- **Never leak actor, tenant, or values into lineage.** Facets carry structural
  names only — job, resource, action, table. Never actor identities, never
  tenant ids, never filter/argument values, in any facet, ever. The suite's
  leak test is the enforcement; any new facet needs to pass it. Transport
  `meta` is not an exception to this: it is in-process context for the
  transport, never serialised by the library and never copied into the
  event. Don't move `meta` values into a facet or the event in a custom
  transport either; store them beside the event (a tenant column, say).
- **Never fabricate a parent.** Depth above zero without a configured
  `:parent_id_provider` omits the parent facet; don't "fix" that by inventing a
  parent id. Configure the provider instead.
- **Never guess datasets.** The dataset comes from the resource's
  `postgres do table end` declaration; a resource without one emits no dataset.
  Don't derive names from module names or atoms to fill the gap.
- **Never crash the host for lineage's sake.** The notifier logs transport
  failures and moves on; keep custom transports raise-free (`{:error, term}`
  is the error channel).

## KNOW

- Reads are never emitted, and resource START/FAIL are out of scope by design
  (ADR 0012): a notifier can only state what already happened. Use
  `emit/2`/`fail/3` for anything the host drives itself.
- `namespace` defaults to the domain module's last segment, underscored.
  Override it when other producers write to the same catalogue — a mismatched
  namespace splits one table into two unrelated datasets silently.
- Dataset entries for `emit/2`/`fail/3` may be bare strings (placed in the
  job's namespace), `{namespace, name}` tuples, or maps with `name` and
  optional `namespace`/`facets`, atom- or string-keyed.
- The extension is spec **2-0-2**; the vendored schema in
  `priv/openlineage/s/run-event.json` is the conformance ground truth.
