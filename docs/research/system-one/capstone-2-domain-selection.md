# Capstone 2 domain selection — decision record (S1-60)

**Date:** 2026-10-02 · **Status:** recommendation recorded; awaits operator confirmation (AC-1)
**Order (Luke, in the ticket):** code standards first, licence policy second. **Both verified GO; the licence domain's ground truth is re-pointed** (§2).

## Criterion scores

| Criterion | Domain 1: code standards | Domain 2: licence policy |
|---|---|---|
| Subject data available today | **5/5** — file/line spans + stable name-paths (`ash_agent_tools` `symbols.ex`, `name_path.ex`), deterministic line-addressable JSON laws judge (files/diffs/snippets), disciplined git histories (225 commits ash_enterprise, 104 clinic-demo…), strict reasoned credo baselines | **4/5** — 181 unique dep subjects across 12 first-party mix.locks (168 in ash_enterprise alone); declared licences present and accurate (10/10 LICENSE↔mix.exs, 5/5 hex↔repo spot checks, checked 2026-10-02) |
| Ground truth that actually works | **5/5** — 19/26 laws have deterministic detectors (seed labels day one); the 7 behavioural laws are the human-approval showcase, which is the demo's premise | **3/5 → re-pointed** — **ClearlyDefined has NO Hex data** (probed 2026-10-02: valid coordinates return HTTP 200 with 0-byte bodies; corpus pattern query returns `[]`; only a POST /harvest — an outward write — would change that). Working adjudicator: **hex.pm package-level `meta.licenses` + each pinned dep's shipped `deps/<pkg>/mix.exs`, validated against the SPDX 740-id list** |
| n for the eval-set programme (≥200/family, per the S1-25 design) | Ample (every function/module/diff/doc paragraph is a subject) | **181 < 200 from own trees** — top up with a small public hex.pm crawl (~16k packages available; a crawl, not a data problem) |
| Blocking gaps | None fatal: doc paragraphs and commit messages lack span-addressable subjects; ADR 0038's model-call table not yet encoded as detectors — all inside CAP2-CODE-SUBJECTS' declared scope | `ash_greenmask` is not a mix project (LICENSE+README only) — exclude or bootstrap it; ClearlyDefined reuse terms unconfirmed (moot after re-pointing) |

## Decision (recommended, awaiting confirm)

1. **Domain 1 — code standards — GO, first.** The subject tooling is production-ready; 19/26 laws give deterministic seed labels while the remaining 7 exercise the approval loop.
2. **Domain 2 — licence policy — GO, second, with ground truth re-pointed** from ClearlyDefined/SPDX to **hex.pm + shipped mix.exs + SPDX**. This changes S1-63's spec: its title's "ClearlyDefined/SPDX as ground truth" becomes "hex.pm/SPDX"; no POST /harvest is sent (outward write, and pointless for a prototype).

## Recorded discrepancies (feed the curation step)

- `ash_strangler`, `ash_greenmask`, `ash_events_projections` live in `~/`, not `~/ast-forks/`; `ast-forks` additionally holds the community forks.
- First-party metadata is consistent everywhere checked; hex.pm release-level `licenses` is null by API shape — historical disputes resolve to the shipped version-exact `deps/<pkg>/mix.exs`, which we hold locally (offline ground truth).
- CLAUDE.md vs `doc/claude.md` duplication across repos needs one canonical source per question clause for CAP2-POLICY lineage.

*Evidence: API probes executed 2026-10-02 (ClearlyDefined, hex.pm, SPDX license-list-data v3.29.0); repo/mix.lock counts and tooling citations in the investigation report (session exp-1, 2026-10-02). No customer data.*
