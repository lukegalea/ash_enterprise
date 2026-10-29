# Bleeding-edge dependencies

Most of this application is built on released Hex packages. Some of it is not. This page lists every dependency that
is not a plain Hex release, why it is not, and how each gets back to one. Read it before you start a new application
from this template, because each of these pieces is yours to carry until it gets back to a Hex release.

Things change in one of three ways:

1. **Forks** of someone else's package, carrying patches upstream does not have yet. These are the real bleeding edge.
   Each one has an upstream it should return to.
2. **Unreleased first-party packages**: our own libraries, public on GitHub but not on Hex yet. They track their own
   `main`.
3. **Host-side workarounds**: code in this application that exists only because a dependency has a bug. Delete each
   one when the bug is fixed upstream.

`mix.lock` pins every git dependency to an exact commit, so builds are reproducible either way. "Bleeding edge" is
about what you are signing up to maintain, not about builds drifting. CI's `cold-clone` job proves every git
dependency can be fetched anonymously.

`test/ash_enterprise/bleeding_edge_doc_test.exs` fails if a git dependency or an `override: true` exists in `mix.exs` or
`mix.lock` without being named on this page. Add the row in the same commit as the dependency.

Facts below were checked on **2026-10-15**. Upstream status goes stale quickly, so check it before acting on it.

## 1. Forks

| Package | Upstream | Our fork (pinned by) | What the fork adds |
|---|---|---|---|
| `ash_events` | [ash-project/ash_events](https://github.com/ash-project/ash_events), Hex 0.8.2 | [lukegalea/ash_events](https://github.com/lukegalea/ash_events), branch `temporal-as-of-support-0.7` (this app, with `override: true`) | Records a write's `as_of` on its event and restores it on replay; marks the replay wrappers `temporal_safe?`; replays in chronological order. Needed for audited temporal resources (the System One facts table). |
| `boxic_dmn` | `boxic_dmn` in [koenusz/boxic](https://github.com/koenusz/boxic), Hex 0.3.0 | [lukegalea/boxic_dmn](https://github.com/lukegalea/boxic_dmn) at `7cb79cd` (`ash_decisions`; arrives here transitively) | `Boxic.DMN.evaluate_with_trace/3,4`, which returns the matched rule ids and hit policy with the value. This is the provenance a decision's audit trail is built on. It also relaxes the Elixir requirement to `~> 1.18`. Versioned `0.4.0`. |

### `ash_events`: path back

- **Upstream status:** issue [ash_events#103](https://github.com/ash-project/ash_events/issues/103) is open.
  [PR #104](https://github.com/ash-project/ash_events/pull/104) is open, mergeable and not yet reviewed. It carries the
  same three commits, rebased onto upstream `main` (0.8.x).
- **The gap:** the pinned branch is v0.7.0 plus those three commits. Upstream has since released 0.8.0–0.8.2, which
  this app does not have.
- **Who declares it.** Every one of these has to move:

  | Declared by | Declaration | Blocks a Hex-only build? |
  |---|---|---|
  | this app | fork branch, `override: true` | yes |
  | `ash_judgments` | fork branch, `optional: true, override: true` | yes |
  | `ash_discrete_business_events` | fork branch | yes |
  | `ash_compliance` | `~> 0.7.0` | yes: it excludes 0.8 |
  | `ash_events_projections` | `~> 0.6` | no |

  `override: true` exists because one package cannot resolve from both Hex and git. Drop it when nothing declares
  the fork.
- **Steps back to Hex:**
  1. Get #104 merged and released.
  2. Widen `ash_compliance` to accept that release. Point `ash_judgments` and `ash_discrete_business_events` at Hex.
  3. Here, replace the declaration with `{:ash_events, "~> <release>"}`. Run `mix deps.update ash_events`, the full
     suite (the replay and temporal tests especially) and `mix ash.codegen --check`.
- **Interim option:** pin the PR branch, `temporal-as-of-support` (0.8-based), instead of the 0.7 branch. That
  closes the 0.8 gap before #104 merges. It needs step 2's `ash_compliance` change first.
- **The 0.7 branch is a dead end:** its own lock lists ash 3.14.1, which has no `temporal` DSL, so its test suite
  does not compile without bumping ash locally. That is another reason to move to the 0.8-based branch.
- **Sensitive values: upstream will not take this.** Since 0.8.0 upstream's README says the library does not
  filter `changed_attributes` on `sensitive?`, because replay needs derived secrets such as `hashed_password`
  (commits `ebc0d2b`, `2d7ccb0`, 2026-09-11). Their answer is to encrypt the event log with `cloak_vault`. The fork branch
  `fix/sensitive-changed-attributes` (`806954e`, on top of the pinned 0.7 branch, not merged) applies the `data` rule
  to `changed_attributes`, with a `store_sensitive_attributes` opt-in for attributes that replay needs. Treat it as a
  fork-only patch, not a path back. The durable options are in section 3.

### `boxic_dmn`: path back

- **Upstream status:** nothing has been proposed upstream yet. No issue or PR exists on koenusz/boxic.
- **Steps back to Hex:**
  1. Propose `evaluate_with_trace` upstream.
  2. When a Hex release carries it, change `ash_decisions` to `{:boxic_dmn, "~> <release>"}`. This app only runs
     `mix deps.update boxic_dmn`.
- **Watch for:**
  - The fork calls itself `0.4.0`. An upstream `0.4.0` would be a different package under the same number. The lock
    pins by commit, so nothing breaks today, but compare contents rather than version numbers when switching.
  - The fork relaxed the Elixir requirement. Check upstream's requirement against this app's Elixir before switching.
- **Runtime note:** `boxic_dmn` validates DMN by shelling out to `xmllint`, so `libxml2` is a runtime dependency (see
  `devenv.nix` and the boot check in `AshEnterprise.Application`). That is true of upstream too.

### Dev tooling forks (not part of the build)

[lukegalea/expert](https://github.com/lukegalea/expert) is a fork of the Expert language server, on branch
`fix/document-symbol-crashes`. It is only used if you point Serena at it (`.mcp.json`,
`docs/research/serena-semantic-edits.md`). Nothing in `mix.exs` depends on it, and a template app can ignore it.

## 2. Unreleased first-party packages

These are our own libraries. They are public on GitHub, declared as `github:` dependencies that track `main`, and
pinned by `mix.lock`. Updating one is `mix deps.update <name>` followed by `mix ash.codegen --check`, because some
packages add columns to resources this app owns. Most are tier 3 in [thesis 6](manifesto/06-reversibility.md):
confined so that removing one is a deletion, not a refactor.

| Package | Used here for | Git dependencies of its own | Publishable to Hex now? |
|---|---|---|---|
| `ash_a2ui` | agent-renderable UI surfaces (ADR 0033) | none | yes |
| `ash_strangler` | strangler-fig read model over `legacy.*` (ADR 0009) | none | yes |
| `ash_open_lineage` | OpenLineage emission (ADR 0012) | none | yes |
| `ash_acp` | Agent Client Protocol adapter | none | yes |
| `ash_rules` | rule IR, fact schemas, evaluator | none | yes |
| `ash_events_projections` | projector engine (transitive, via `ash_compliance`) | none | yes |
| `ash_evidence` | evidence pipeline records (System One); declared `branch: "main"` | none | yes |
| `ash_bpmn` | BPMN process engine (ADR 0009) | none | yes |
| `ash_agent` | agent runtime fragments, extension and host behaviours (ADR 0056); upstream [lukegalea/ash_agent](https://github.com/lukegalea/ash_agent); `Execution.Invocation` instantiates the invocation fragment | none | none planned: the Hex name `ash_agent` belongs to an unrelated project (ADR 0056) |
| `ash_compliance` | compliance bundles and findings (ADR 0035) | `ash_rules`, `ash_events_projections` | after those two |
| `ash_decisions` | DMN decisions | `boxic_dmn` fork | no: needs `boxic_dmn` upstream |
| `ash_discrete_business_events` | business-event ledger (ADR 0051) | `ash_events` fork | no: needs `ash_events` upstream |
| `ash_mdm` | master data: mappings, matching, survivorship merge (ADR 0054) | `ash_discrete_business_events` | no: after `ash_discrete_business_events` |
| `ash_judgments` | judgment substrate (System One); tracks the default branch, declared without `branch:` to match `ash_agent_tools` | `ash_rules`, `ash_compliance`, `ash_bpmn`, `ash_decisions`, `ash_events` fork | no: needs both forks gone |
| `ash_agent_tools` | read-only Ash introspection for coding agents, and the code subjects the standards are judged over (dev and test only) | `ash_rules`, `ash_bpmn`, `ash_decisions`, `ash_judgments` (all optional) | after those four, so after `boxic_dmn` and both forks |

**Path to Hex:** a Hex package can only depend on Hex packages, so publish from the leaves up:
1. The packages with no git dependencies of their own.
2. `ash_compliance`.
3. `ash_decisions`, `ash_discrete_business_events` and `ash_judgments`, which are blocked on the forks in section 1,
   then `ash_mdm` and `ash_agent_tools`. Optional dependencies count: Hex still needs them to be Hex packages.

`ash_agent` is not on this path. It has no git dependencies of its own, but the Hex name belongs to another project,
so it stays a git dependency. Reaching Hex would mean renaming the package (ADR 0056).

As each lands on Hex, replace its `github:` declaration in `mix.exs` with a version requirement and delete its row
here.

**If your app can't carry git dependencies:** each package above has an entry in `mix.exs` that says which part of
this app uses it. Removing a tier-3 package means deleting the directory it is confined to; the ADR named in the
table gives the reversal path.

### Not bleeding edge

`heroicons` is a git dependency because that is how Phoenix ships it: the upstream `v2.2.0` release tag, fetched as
assets (`app: false, compile: false`). It is a release, not a fork.

## 3. Host-side workarounds for dependency bugs

| Workaround | Works around | Remove when |
|---|---|---|
| `AshEnterprise.Audit.Changes.RedactSensitive` (8c40d2d; runbook `docs/runbooks/audit-sensitive-values.md`) | `ash_events` builds `changed_attributes` without checking `sensitive?`, so a value a change computes is logged in the clear. The first case found was `User.hashed_password`. | Probably never. Since 0.8.0 upstream documents that it will not filter these and recommends `cloak_vault` (an encrypted event log) instead. Removing this needs either that, or the fork patch described under `ash_events` in section 1 plus `store_sensitive_attributes [:encrypted_*]` on every cloaked resource. Either way, the `ash_cloak` ciphertext must still reach the log, because ADR 0024's crypto-shredding relies on it and `ash_cloak` marks those columns `sensitive?`. |
| `AshEnterprise.SystemOne.JudgedFields.Calculation` writes each mode (`:tri_state`, `:status`, `:reason`) as one flat `cond` instead of nesting the tri-state inside the others (S1-53) | `ash_sql` leaves the literal `THEN` parameters of a `cond` nested inside a `cond` of another type uncast, so Postgres infers them from the outer `CASE` (`varchar`) and Postgrex refuses to encode `true` as text (`DBConnection.EncodeError`). | `ash_sql` casts literal `CASE` branch parameters to their expression type; then `:status`/`:reason` can reuse the `:tri_state` expression. |
| `CalendarEvent.upsert_from_source` names `:updated_at` and `:modified_on` in `upsert_fields` (PROD-47) | `ash_postgres` 2.14.3's temporal upsert (its `upsert_all/6`) sets only the `upsert_fields` on a match; its plain upsert also refreshes update defaults (`touch_update_defaults?`). A new version kept the first write's `updated_at`, and the business event derived from it the wrong `occurred_at`. | The temporal upsert touches update defaults like the plain one. |
| `AshEnterprise.Canonical.Changes.KeepUnchangedVersion` (PROD-47) | The temporal upsert splits the version valid at the write's instant on every match, even when no value changes, and ignores `upsert_condition`, so a replay or a provider re-report adds an identical version per event. The change compares the projected values and returns the current version (`Ash.Changeset.set_result/2`). | The temporal upsert honours `upsert_condition` (or skips identical rows); the sealed fields would still need comparing in the clear, so the change may stay for those. |
| `AshEnterprise.Canonical.CalendarEvent.TemporalCutover` (custom statements; migration `20261022161918`) | Making an existing table temporal, the `ash_postgres` migration generator adds the period and drops the foreign keys touching the table, but leaves the plain `(id)` primary key and the plain unique identity indexes (both refuse a second version), and drops foreign keys from the temporal table to ordinary ones, which are enforceable. | The generator converts an existing table: key, identities, and keeps outbound foreign keys. Then the statements are no-ops on a fresh database and can go. |

Add a row whenever this app works around a dependency bug instead of fixing it there. A workaround that is not
listed gets forgotten.
