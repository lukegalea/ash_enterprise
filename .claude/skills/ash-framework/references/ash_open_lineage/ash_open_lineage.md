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
  `config :ash_open_lineage, correlation_provider: MyApp.Correlation` — lineage
  run ids should *be* the host's correlation ids, or the graph and the audit
  trail cannot be joined. Without one you get throwaway UUIDs per event.
- **Configure the transport before first use.**
  Resources: per-resource `transport` in the `lineage` section.
  `emit/2`/`fail/3`: `config :ash_open_lineage, transport: ...` (default
  `Req`, which needs `config :ash_open_lineage, http_base_url: "http://localhost:5000"`).
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
  three events form one run.

## NEVER

- **Never leak actor, tenant, or values into lineage.** Facets carry structural
  names only — job, resource, action, table. Never actor identities, never
  tenant ids, never filter/argument values, in any facet, ever. The suite's
  leak test is the enforcement; any new facet needs to pass it.
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
- The extension is spec **2-0-2**; the vendored schema in
  `priv/openlineage/s/run-event.json` is the conformance ground truth.
