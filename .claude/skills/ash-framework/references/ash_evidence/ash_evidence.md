# Usage rules

Rules for working with `ash_evidence`, maintained for
[`usage_rules`](https://hex.pm/packages/usage_rules) sync. The package
contract below is binding on every change — in this repository and in
consumers.

## What the package is

The evidence pipeline substrate: immutable document versions (`AshEvidence.DocumentVersion`),
instrument parse runs (`AshEvidence.ParseRun`), the addressed atoms a pass
produced (`AshEvidence.AddressedAtom`), their retrieval projections
(`AshEvidence.AtomRepresentation`), the retrieval proofs
(`AshEvidence.CandidateSet`), the adjudication run rows and packets
(`AshEvidence.EvidenceEvaluation`, `AshEvidence.Packet`), and the assertion
fragment hosts compose (`AshEvidence.Assertions.Fragment`) with the versioned
aggregation rule (`AshEvidence.Assertions.Aggregation`).

## What it never does — do not make it

- **Never call an instrument from this package.** No HTTP client, no Req, no
  model id, no endpoint, no key literal — in source, config or fixtures. The
  host starts a `ParseRun`, does its OCR/LLM work outside, and closes the run.
  The same applies to embeddings and adjudication: the host embeds and judges;
  `retrieve/3`, `record_embedding` and the aggregation only ever record, score
  and compose what the host computed.
- **Never narrow citations here.** `AddressedAtom.source_ids` records what the
  instrument client already enum-narrowed to the packet's atom ids. A
  validation here cannot repair an unfiltered reply.
- **Never mutate the record.** No update action on `DocumentVersion` (new
  rendition ⇒ new version); run and evaluation transitions are terminal
  (`:pending → :ok` / `:pending → :failed`, once); a correction is a new
  record — including a re-run retrieval or re-adjudication, which are new
  `CandidateSet`/assertion rows, never updates.
- **Never let text or answers leak.** Atom ids are the packet currency;
  `text`/`bytes`/`bbox`/`embedding` resolve from the store and are payload
  class. A `CandidateSet` stores hashes and ids only. A `Packet` stores ids
  and the observation JOIN — the validation rejects any inner key beyond
  `observation_id` + `question_hash`, so a copied answer has nowhere to go.
  The assertion stores digests and decimal strings only.
- **Never decide anything.** No thresholds, no policy, no verdicts derived
  from atoms. Retrieval scores rank matches; the aggregation composes
  marginals and applies ONE fixed invariant (a credible contradiction
  dominates support) — thresholds and bands stay in the host's DMN.

## Working with the resources

- Call through the domain code interfaces and the seams (`AshEvidence.retrieve/3`,
  `AshEvidence.explanation/1`, `AshEvidence.Assertions.Aggregation.aggregate/1`).
- **The assertion is a fragment.** Define the persisted assertion resource on
  YOUR base (`use Ash.Resource, ..., fragments: [AshEvidence.Assertions.Fragment]`)
  so your AshEvents audit, tenancy and policies apply; the package never
  defines it. The `:record` create is inputs-only with one pure derived
  change — keep it that way (replay rebuilds rows, never re-runs a model).
- Run the aggregation in the orchestrator BEFORE the assertion create, and
  record `rule_version` with it. A rule recalibration is a NEW version.
- Retrieve with `persist?: true` inside an adjudication loop, and cite the
  `candidate_set_id`s on the evaluation — the packet's proof-of-search is
  citation, never duplication.
- Retrieve under competing hypotheses (`:supports` + `:contradicts` at
  minimum; `:exception` when the predicate can have exceptions). Retrieving
  for support only manufactures false supports. Each framing runs its own
  query — pass `queries:` when the host's model writes the counter-hypothesis.
- Keep embeddings comparable: score against `embedding_model`-scoped
  representations (cosine across models is meaningless), and re-project +
  re-embed when a representation changes (re-projecting voids the stale
  vector).
- Distribution values are DECIMAL STRINGS (`"0.97"`, §4.3) — the DMN bridge
  reads decimals; probabilities never cross a record boundary as floats.
- Erasure: the assertion survives (envelope-class, no FKs into the evidence
  tables); packet/evaluation/candidate-set references may dangle — read them
  through `AshEvidence.explanation/1`, which degrades honestly
  (`unresolved_source_ids`).
- Point `AshEvidence.Repo` at the host's own database (residency is the
  host's concern); PostgreSQL 18 is the declared floor, with the `vector`
  extension installed.
