# AshPlanning usage rules

- Planning **proposes**; people commit. Never apply a candidate from machinery. Apply,
  approve and reject are host actions behind human-only policies — the package ships none.
- Fragments are pure shape. Add policies, multitenancy, ownership, audit, relationships,
  the data layer and sealing of `problem_payload`/`result_payload`/`assignments`/
  `violation_details` in the **host** resource. Fragments never reference host modules.
- Hosts must set `config :ash, default_string_length_count: ...` (fragments use string
  length constraints). Data layers without native identity checks (ETS) need
  `pre_check_with` — a host concern.
- Honest outcomes: `:infeasible` only when UNSAT is proven; a timeout with an incumbent is
  `:feasible` + `complete?: false`; without one, `:unknown`. `optimality: :proven` only with
  a solver certificate — a checker is never one.
- Numbers are `Decimal`, never `Float`. Violations carry structural values only.
- Validators (`AshPlanning.Validator`) must be written independently of the model; do not
  share lowering code between model and validator. Intervals are half-open `[start, end)`.
- Snapshots carry references and hashes only. Verify with `AshPlanning.Snapshot.verify/1`;
  the cross-host golden digest is asserted in this package's tests.
- Solverl is optional. Guard calls with `Code.ensure_loaded?(AshPlanning.Backend.Solverl)`.
  The Solverl backend refuses to run without `prlimit` (`:resource_governor_unavailable`)
  and never kills by process name.
- Fixtures in `test/` and `priv/` are synthetic. `mix planning.boundary` enforces it.
