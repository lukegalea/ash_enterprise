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
(`AshEvidence.EvidenceEvaluation`, `AshEvidence.Packet`), the assertion
fragment hosts compose (`AshEvidence.Assertions.Fragment`) with the versioned
aggregation rule (`AshEvidence.Assertions.Aggregation`), and the eval-set
layer (`AshEvidence.EvalSet`, `AshEvidence.EvalItem`,
`AshEvidence.EvalSets.Draw`, the synthetic CC0 corpus).

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
  `text`/`bytes`/`geometry`/`embedding` resolve from the store and are payload
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
  record its `rule_version` as the assertion's `aggregation_rule_version`.
  A rule recalibration is a NEW version.
- Ingest every atom with its `kind` (`:word`, `:line`, `:cell`, `:region`)
  and, when the input has pages, its 1-based `page`. Record a box as
  `geometry` (`AshEvidence.AtomGeometry`): the measured `page_w`/`page_h`
  in `unit` (`:pt` or `:px`), the `rotation_applied` in degrees, and `bbox`
  `%{x0, y0, x1, y1}` normalised to `[0, 1]` with a top-left origin —
  divide by the page size before ingesting, never store raw coordinates.
  A composite atom (a line, a cell, a region) cites its parts in
  `source_ids`, in reading order; there are no character offsets. A run
  that rotated or deskewed a page records it under the run `config`'s
  `"page_transforms"` key.
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
- **Tenants.** `DocumentVersion` is multitenant by attribute with
  `global? true`: once you tenant, pass the tenant on every version read and
  write, because an untenanted read sees every tenant. Content addressing is
  per tenant (identical bytes in two tenants are two rows). Runs, atoms,
  representations, candidate sets, evaluations and eval items carry no tenant
  column but are scoped through their version when you pass `tenant:` (writes
  check the version is in that tenant; reads filter by it; `retrieve/3` takes
  `tenant:`). Without `tenant:` nothing is scoped. Packets and eval sets are
  not scoped themselves. Host repos also need `"ash-functions"` in
  `installed_extensions/0`.
- **Erase a document with `AshEvidence.Domain.destroy_document_version/1-2`**
  (pass `tenant:`). The database cascade removes its runs, atoms,
  representations, candidate sets, evaluations, packets and eval items; do not
  delete atoms and runs by hand first. Erase host documents only, never corpus
  versions: eval items that cite a version go with it.
- Erasure: the assertion survives (envelope-class, no FKs into the evidence
  tables); packet/evaluation/candidate-set references may dangle — read them
  through `AshEvidence.explanation/1`, which degrades honestly
  (`unresolved_source_ids`).
- Eval sets are versioned and frozen: items never move between splits and a
  published set accepts nothing — a correction is a new set version. The
  draw runs from the set's recorded seed (`EvalSets.Draw`); `:audit` rows
  arrive with their explicit split and are honoured verbatim, never drawn.
  Eval-set membership lives on the eval set, never on `AddressedAtom`/
  `ParseRun`. The shipped corpus is synthetic and CC0-dedicated — real
  labelled material stays in-region and private (DEC-MOAT).
- To write versions in your own transaction, set
  `config :ash_evidence, :repo, MyApp.Repo`. Your repo must provide the
  `vector` extension, Postgrex `types:` that include
  `AshPostgres.Extensions.Vector`, PostgreSQL 18, and a `default_prefix/0`
  naming the schema the evidence migrations ran into. Keep `AshEvidence.Repo`
  configured (and in `ecto_repos`) against the same database so the migrations
  run; it need not start at runtime. Never add `AshEvidence.Domain` to your
  own app's `ash_domains`: your codegen would generate the evidence tables into
  your migrations.
- Set `config :ash_evidence, AshEvidence.Repo, priv: "priv/repo"`: that directory
  holds exactly the package's migrations. `priv/test_repo` holds the package's
  own test-host tables (`test_host_*`); never point a host at it.
- Point `AshEvidence.Repo` at the host's own database (residency is the
  host's concern); PostgreSQL 18 is the declared floor, with the `vector`
  extension installed. A host with its own schema sets `default_prefix:` and
  `migration_default_prefix:` (same repo config) to it and puts it first on
  the repo's `search_path`; a migration resolves a foreign key with
  `prefix()`, never a literal `"public"`.
