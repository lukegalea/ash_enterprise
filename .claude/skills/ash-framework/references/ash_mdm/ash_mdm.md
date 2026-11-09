# ash_mdm usage rules

`ash_mdm` ships resource macros, not concrete resources. The host instantiates
them on its own platform base — host policies, tenancy and audit govern
natively; the package never assumes an actor model.

- Six macros, each used inside the host's own `use Ash.Resource` module:
  `use AshMdm.Resources, {:mapping, repo: ..., table: ..., tenant?: false}`,
  `{:match_rule_set, repo: ..., table: ...}` and `{:match_candidate, opts}`.
  `:mapping` and `:match_rule_set` own their `postgres` block (`:repo` and
  `:table` are required); `:match_candidate` ignores its options and emits no
  `postgres` block, so the host supplies the data layer config. Pass
  `tenant?: true` on `:mapping` and `:match_rule_set` when the host base
  supplies `organization_id`; it joins the one-active unique index and scopes
  activation's supersedence to the tenant.
- Mapping targets resolve only against the host's allowlist,
  `config :ash_mdm, :allowed_targets, %{"MyApp.Person" => MyApp.Person}`
  (string name → module). It fails closed: with no allowlist configured, or a
  `target_resource` outside it, the validator reports `:unknown_target` and
  the mapping cannot be validated.
- Mappings are versioned data with a closed operator vocabulary. Never add an
  eval-based operator; unknown operators are validation errors by design.
- Survivorship is data on the match rule set, with a closed strategy set:
  `most_recent`, `source_rank`, `most_complete`, `non_null` (the default) and
  `steward_override` (`AshMdm.Survivorship.strategies/0`). `:activate` refuses
  a rule set whose survivorship names any other strategy. `source_rank` needs
  a real source per candidate: a host folding golden records with no per-field
  source lineage cannot supply one and should refuse the merge, not pass
  placeholder source names (they tie, and the first record wins silently).
- Survivorship also has `origin_rank`, which ranks by where a statement came
  from. It has no default order: `:activate` refuses it without an
  `origin_rank` list of kinds from `AshMdm.Assertions.rankable_origin_kinds/0`.
- `{:attribute_assertion, repo: ..., table: ..., tenant?: false,
  sensitive_value?: false}` is one append-only row per statement that an
  attribute of a golden has a value, with its origin. Write with `:assert`;
  there is no update. Correct by asserting again, and withdraw with
  `origin_kind: :retraction` and `retracts_id`. Identical content is one row,
  so a retried job is safe. `:erase` exists only for a host's erasure path.
- `:erase` must be a real delete. On a base with AshArchival it becomes a soft
  delete and the plaintext stays, so such a resource must opt out of archival.
- `tenant?: true` on `:attribute_assertion` requires real Ash multitenancy,
  because the digest identity is otherwise global: two tenants' identical
  statements would be one row.
- `sensitive_value?: true` requires `digest_secret: {Module, :function, args}`,
  returning a binary; the macro raises `ArgumentError` at compile time without
  it. `content_digest` is then an HMAC-SHA256 under that secret, because an
  unsalted hash of a low-entropy value such as a government identifier can be
  brute-forced. Rotating the secret changes every digest, so a statement
  already stored would not dedupe against its re-import.
- A retraction must be written on the same golden as its target, or an unmerge
  will undo it. Only a retraction banded nil or `:admit` takes effect.
  Retracting a retraction restores its target; a retraction of a retraction
  must carry a later `observed_at` than the one it withdraws.
- A source cannot say a value is gone by asserting nil: `:assert` refuses a
  statement with no value. To say so, withdraw every statement it made, by
  retraction.
- `AshMdm.Assertions.fold/3` is the fold over those rows. Band `:review` or
  `:omit`, retracted and blank statements do not compete; expired ones do.
  Only a source's newest statement on an attribute competes, so re-asserting
  corrects a value. Date a re-import by when the source said it, not when it
  was read, or an identical value becomes a new row. Within one merge-chain
  depth a `:human` statement sorts first, so a steward's value beats an older
  import under the default `non_null`; a survivor's value still beats an
  absorbed golden's, even a person's.
  Give all stewards one `source` and record who said it in `origin_ref`: among
  people the oldest order still holds, so a user id as the `source` makes the
  first steward's value outrank every later correction.
  Pass `depths:` from `chain_depths/2` so a survivor outranks what it absorbed.
  Don't rewrite an absorbed golden's assertions on merge: leave them and fold
  through the chain, so an unmerge is correct by construction.
- The attribute assertion macro ships no read policy and has no foreign key
  to the golden. A host must gate its reads on the golden, or the table
  discloses what the golden's own policies hide. Do it in the read, as a
  preparation or action filter: Ash does not authorize an `exists` written
  inside a policy, so that form lets every reader through.
- `{:completeness_profile, repo: ..., table: ..., tenant?: false}` declares,
  per golden resource and purpose, what each attribute needs and why. It has
  the same draft, validate, activate lifecycle as a mapping, and the same
  total accounting: every public attribute appears once, `required`,
  `optional` or `out_of_scope`, each with a `because`.
- `accepted_origins` is a list per requirement, not a global strength order.
  Don't add a ranking of origins to answer "is this good enough".
- `AshMdm.Completeness.assess/3` is the pure answer, one entry per required
  attribute. It judges a requirement against every competing statement holding
  the standing value, so an import later confirmed by an accepted origin or
  fresher evidence closes the gap; a different value does not. A tie names the
  statement that keeps the outcome longest, since a projected row re-judges
  only that one. `{:attribute_gap, ...}` is its rebuildable projection so a board
  can filter and count. Project with `:project`. It stores inputs, never a
  value; `gap_kind` is computed at read, so nothing has to run for a value to
  go stale. Don't add a stored status.
- The attribute gap macro ships no read policy either. Gate it on the golden.
- `{:resolver, repo: ..., table: ..., tenant?: false}` declares one way to
  produce attributes of a golden, as versioned data with the same draft,
  validate, activate lifecycle and one-active index (per golden and name). Its
  `kind` is closed (`AshMdm.Resolution.kinds/0`): `human`, `inference`,
  `judgment`, `evidence`, `enrichment`. `:validate` refuses an unknown kind,
  empty `produces`, an attribute both produced and required, a non-positive
  `cost_rank`, an empty `reference`, and attributes the golden does not have.
  `reference` is the host's own account of what runs it; the package never
  interprets it.
- `AshMdm.Resolution.plan/3` takes the gaps from `AshMdm.Completeness.gaps/3`,
  the active resolvers and the attributes already held, and answers per gap
  `:planned`, `:needs_input` or `:no_route`. Greedy by `cost_rank` then name; a
  chain resolves in rounds, a requires cycle ends in `:needs_input`. A material
  gap planned to a non-human kind comes back `needs_person: true`: the planner
  never decides a person is unnecessary. A gap's `accepted_origins` narrow the
  candidates to resolvers that can land an accepted origin (on a material gap,
  that origin is `human`); if none can, the answer is `:no_route`. Only gaps
  are planned, so a requirement that is not a gap comes back `:needs_input`
  even if a resolver could produce it. It runs nothing and stores nothing;
  executing a step and recording the attempt are host code.
- `AshMdm.Tuning.propose/2` turns judged pairs into proposed rule weights.
  Write the result with the rule set's `:create_version` and have a person
  activate it. Never apply a proposal directly: a new content hash means the
  bands must be earned again. When some rules lack labels and others are
  tuned, the weights that were earned are rescaled to keep the tuned rules'
  combined share and a floored rule stays at the floor; a rule set tuned whole
  is not rescaled.
- A match rule may list `"standardize"`, a closed vocabulary in
  `AshMdm.Standardize`, applied after trim and lowercase. `lei` returns nil for
  a value that fails its check, so a bad identifier counts as absent. A rule
  using `legal_suffix` should not decide a merge alone: two companies can
  share a stem. `unaccent` removes combining marks only after a Latin base
  letter, because marks in other scripts distinguish words. A blank value is
  missing, not agreement, including one a standardizer has emptied.
  `legal_suffix` strips the Italian form only as dotted `S.p.A.`; bare `spa` is
  a word.
- `:activate` refuses a rule with an unknown kind, algorithm or standardizer,
  a non-positive weight, or a duplicate name. A missing value adds
  `"missing" => true` to that rule's explanation entry.
- Every create action on a versioned resource stamps `content_hash` with
  `AshMdm.Changes.SetContentHash`, whose `fields:` option names what the hash
  covers: `field_rules` on a mapping, `rules` and `survivorship` on a rule set.
- `AshMdm.Survivorship.resolve/2` returns `%{merged:, provenance:}`.
  `provenance` is the per-attribute winner and strategy: record it with the
  merge rather than discarding it.
- Thresholds (match bands) are never literals in package code — they are host
  band-table decisions. The package carries scores and explanations only.
- A `:match_rule_set`'s one-active partial unique index is the macro's, so a
  host needs a migration for it: run `mix ash.codegen` after upgrading.
- Match candidates: the machine `:update` writes `:band` and the machine
  statuses (`:pending`, `:auto_merged`, `:superseded`); it refuses to set
  `:confirmed` or `:rejected`. Those are a person's acts, on actions the host
  defines and gates. `:record_verdict_ref` only stamps `human_verdict_ref`
  after such a decision has committed.
- A match candidate pairs a golden with a staged record (`:create`) or with
  another golden of the same `golden_resource` (`:create_golden_pair`): exactly
  one of `staged_record_id` and `other_golden_id` is set, enforced by
  `AshMdm.Validations.ExactlyOnePairing` and by a host check constraint. A
  golden pair is stored with `golden_id < other_golden_id`, a self-pair is
  refused, and the reversed pair is the same candidate (identity
  `:one_golden_pair`; a second create is an identity error). The host owns the
  DDL: `staged_record_id` nullable, `other_golden_id uuid`, a check
  `(staged_record_id IS NULL) <> (other_golden_id IS NULL)`, a unique index
  `<table>_one_golden_pair_index` on `(golden_resource, golden_id,
  other_golden_id) WHERE other_golden_id IS NOT NULL`, plus
  `identity_wheres_to_sql one_golden_pair: "other_golden_id IS NOT NULL"` in
  its `postgres` block. Staged candidates and `:one_pair` are unchanged. A bulk
  upsert must not carry one pair twice in a batch, in either order: Postgres
  refuses the whole batch.
- Merging golden records is host code; the package neither merges nor
  deletes rows. The mapping validator skips the CDM merge columns (`merged`,
  `master_id`) along with the other system columns when it checks total
  accounting.
