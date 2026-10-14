# ash-mdm handoff (ADR 0050 build)

Written 2026-10-14 mid-build. Branch `mdm-0-1`, head `9577597`. Package
`~/ash_mdm` branch `main`, head `7354af7` (pushed). Everything below
"Green" is verified by the named suites; everything under "Open" has its
plan section and acceptance test named.

## Green (suite-verified)

- MDM-0..3 + MDM-4 banding/queue: commits `23e58ce..27b7e52` — suites were
  green at their slice gates (batch 16, mapping 3, merge 3 at latest run).
- MDM-4 remainder: `5d77fa5` (steward queue + person-gated confirm/reject),
  `af1d9e4` (judgment + HumanVerdict + confirm-promotes), `037b341`
  (mdm.steward_review BPMN baseline; instance per review-banded candidate,
  task completed by the decision, decision stays person-gated — no
  service-task merge).
- Gap closure: `dc2d1cc` (band routing: admit auto-merges via AutoMerge,
  omit creates the row's own golden, review → stewardship), `6fa05a4`
  (zero-candidate rows + reject create goldens; batch trio test),
  package `01318cd` (person statuses cannot ride the machine update).
- MDM-6: `7c1e535` (egress export: Person.mdm_export generic action, zone
  disclosure gate on land-recorded residency tags; Landing ISO-normalises
  the region tag), `8f57954` (A2UI surfaces), `6304041` + `71cd5d8`
  (surface fixes; pushed-row assertions: survivor shown, absorbed loser
  never).
- SourceRecord exposure closed: `9577597` — raw landings are
  machinery-visible only; two-tenant test pins it.
- Package suite 51 passed. Host MDM suites: see `/tmp/verify1.txt` output
  of the final run.

## Open slices (build order)

1. **Mdm.Projection.replay + ledger events** (plan §7; earlier handoff
   deferred it on a "person projector decision"). Mirror
   `lib/ash_enterprise/canonical/projection.ex`; rebuild goldens from
   SourceRecords + active mappings + SourceIdentities + recorded decisions
   (MatchCandidate status/human_verdict_ref). merged/master_id default
   false/nil so replay never resurrects merge state. Fixture test:
   byte-identical replay after deleting goldens.
2. **MDM-7 Quality rules** (plan §10): `AshEnterprise.Mdm.QualityRules`
   (`use AshRules`; facts over staged/golden records), catalog
   `mdm-quality`, per-tenant profiles, projector
   `AshEnterprise.Mdm.QualityProjector` (`use AshCompliance.Projector`,
   grain `[organization_id, control_id, subject_type, subject_id]`),
   findings → stewardship task via the existing BPMN audit-event
   subscription (KYC precedent: `lib/ash_enterprise/compliance/kyc_rules.ex`,
   `compliance/projector.ex`).
3. **MDM-8 AI mapping proposals** (plan slice table): draft, never
   activate; `observed_schema` captured at proposal time; the ImportLive
   "AI proposal" button.
4. **Flagship UI**: StewardLive is at `/app/steward`; the plan wants
   `/app/mdm` with a server-rendered side-by-side diff (staged vs golden,
   winner-per-survivorship highlighted, per-field scores) and
   confirm/reject/create-new-golden/unsure-escalate. Also `ImportLive` at
   `/app/mdm/import` (plan §9.1).
5. **Verify** (plan §13): `cs_import_flow`, `lineage`, `projection_replay`
   end-to-end tests; `mix precommit`; roadmap.json `mdm` item → partial
   with named limitations; docs; ash_mdm README push (drafted in
   `~/ash_mdm/README.md`, uncommitted) + screenshots.

## Known correctness bugs (fix before or during the slices above)

1. `Export.residency/1` (`lib/ash_enterprise/mdm/export.ex`): `hd(tags)` —
   one golden with CA and US identities passes the gate on the first tag,
   and `Ash.read_one!` raises on multi-period landings. Take the most
   restrictive tag across ALL identities, use `read_one` with a limit/order.
2. `AutoMerge.create_golden!/3`: `:upsert_from_source` upserts on email —
   a new golden whose email matches an existing Person OVERWRITES it. The
   omit/new-golden path must not upsert: create, or fold via survivorship
   when the email identity already exists.
3. Losing candidates: when several candidates pair one staged row, the
   non-routed losers stay `:pending` forever; they should become
   `:superseded` when the row routes. Staged rows never reach the
   `:review` status the enum declares.
4. Unmerge: does not clear `merge_provenance`, and restoring the prior
   email has no collision handling if the survivor's email changed since.
5. No regression test that the machine `:update` refuses
   `status: :confirmed` (package validates it; untested).
6. StewardLive confirm runs outside the instance task when the queue and
   TaskList race; the second decision of a racing pair currently hits
   `validate attribute_equals(:status, :pending)` — verify that surfaces
   as a flash, not a 500, in the LiveView.

## Verification commands

```
printf 'mix test test/ash_enterprise/mdm/ test/ash_enterprise_web/live/steward_live_test.exs test/ash_enterprise_web/mdm_surfaces_live_test.exs test/ash_enterprise_web/mdm_surfaces_test.exs test/ash_enterprise/mdm/export_test.exs --seed 1 > /tmp/v.txt 2>&1 </dev/null; tail -2 /tmp/v.txt\nexit\n' | devenv shell
```

(mix only exists inside `devenv shell`.) Package: `cd ~/ash_mdm && mix test`.
