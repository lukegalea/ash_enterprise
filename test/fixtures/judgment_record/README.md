<!-- SPDX-License-Identifier: CC0-1.0 -->

# judgment_record fixtures

Synthetic golden fixtures for the frozen v0 judgment record
(`docs/rfc/judgment-record-v0.md` — RFC S1-24, status **"ACCEPTED — v0
FROZEN"**), validated by `AshEnterprise.JudgmentRecord` against
`priv/judgment_record/schema.json`.

## Licence

To the extent possible under law, the author(s) have dedicated all copyright
and related and neighboring rights to the files in this directory to the
public domain worldwide via the **CC0 1.0 Universal Public Domain
Dedication** (`CC0-1.0`). Each fixture carries the marker
`SPDX-License-Identifier: CC0-1.0` in its top-level `$comment` key.
No copyright, no warranty: <https://creativecommons.org/publicdomain/zero/1.0/>.

REUSE-annotate note: the RFC (§15) asks the fixtures to be "synthetic and
REUSE-annotated CC0"; the `$comment` markers above are that annotation, kept
inside the JSON so every fixture stays a single self-describing file.

## Provenance — everything here is synthetic

These records are **fabricated**, in the RFC's own synthetic veterinary
clinic framing (clinic-demo, RFC §0/§12). No question wording, band values,
calibration families, labelled sets or data from any real deployment appear
here (DEC-MOAT). There is no customer content, no document free text and no
endpoints or credentials (§9). The `state` values are numeric/boolean
markers, never prose.

- **Digests**: every `sha256:...` value and every bare model digest is a
  random 64-hex string with no relationship to any real content. Model
  digests are intentionally *bare* hex (no `sha256:` prefix): the RFC keeps
  a model digest in the format its runtime reports (§4.2, Q7 — fetched over
  HTTP at call time), while digests the RFC itself defines are
  `sha256:`-prefixed and full length (§4.2, Q4).
- **Identifiers**: UUIDs are fabricated v7-shaped values; zone `zone.lab`
  and jurisdiction `EX-1` are the RFC's own placeholders (§12, Q18).
- **Probabilities** are decimal strings (§4.3); the distributions sum to 1
  so the fixtures are arithmetically coherent.

## The fixtures

| File | What it covers |
|---|---|
| `observation-noul-live.json` | Noul, `mode: live`, decision rung (the RFC §12 example A). Distribution derived from the single probability; `value` null (Q9). |
| `observation-choice-live.json` | Choice feeding triage; three-way distribution, confidence, human actor. |
| `observation-extraction-generative.json` | Generative rung: `wire_schema_hash` + `sampling` set, `status: found`, `source_ids`, document provenance (parser/atomiser versions), `mode: calibration` with `run_id`, no confidence (ADR 0046 point 5). |
| `observation-evidence-shadow.json` | Evidence kind with atom ids, `mode: shadow` (`shadow_of` set), automation principal + `grant_ref`, mutually exclusive with `system_actor`. |
| `observation-cast-failed-erased.json` | A failure is still an observation: `cast_failed` with an `error` object, `model_digest` null (§5.7 rule 3), payload class erased — `state` and `raw` null (§10/§12). |
| `observation-score-eval.json` | Score kind (decimal-string value, level-index distribution keys), `mode: eval` with `run_id`. |

## Stability

The sha256 of every fixture (and of the RFC text and the schema) is pinned
in `test/ash_enterprise/judgment_record_golden_test.exs`. Any byte drift —
including an accidental edit that "thaws" the frozen RFC — fails the suite.
