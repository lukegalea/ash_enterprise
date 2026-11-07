# ash_mdm usage rules

`ash_mdm` ships resource macros, not concrete resources. The host instantiates
them on its own platform base — host policies, tenancy and audit govern
natively; the package never assumes an actor model.

- Three macros, each used inside the host's own `use Ash.Resource` module:
  `use AshMdm.Resources, {:mapping, repo: ..., table: ..., tenant?: false}`,
  `{:match_rule_set, repo: ..., table: ...}` and `{:match_candidate, opts}`.
  `:mapping` and `:match_rule_set` own their `postgres` block (`:repo` and
  `:table` are required); `:match_candidate` ignores its options and emits no
  `postgres` block, so the host supplies the data layer config. Pass
  `tenant?: true` on `:mapping` when the host base supplies
  `organization_id`; it joins the one-active unique index and scopes
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
  a rule set whose survivorship names any other strategy.
- Thresholds (match bands) are never literals in package code — they are host
  band-table decisions. The package carries scores and explanations only.
- Match candidates: the machine `:update` writes `:band` and the machine
  statuses (`:pending`, `:auto_merged`, `:superseded`); it refuses to set
  `:confirmed` or `:rejected`. Those are a person's acts, on actions the host
  defines and gates. `:record_verdict_ref` only stamps `human_verdict_ref`
  after such a decision has committed.
- Merging golden records is host code; the package neither merges nor
  deletes rows. The mapping validator skips the CDM merge columns (`merged`,
  `master_id`) along with the other system columns when it checks total
  accounting.
