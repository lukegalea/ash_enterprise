# ash_compliance usage rules

_Rules for working with the ash_compliance library, for humans and agents
alike._

## The two planes

The **control plane** — `Catalog`/`CatalogVersion`, `Control`/`ControlRevision`,
`Profile`/`ProfileRevision`, `RuleSetRevision`, `TenantPolicySet`,
`PolicyOverride` (waivers), `ControlMapping` — compiles, through the fixed
layering precedence, into the immutable `PolicyBundle`. The **data plane** is
what evaluation produces: `Finding` rows projected from the event log (the
"now"), append-only `ComplianceEvaluation` records (the auditor's "why"),
and immutable `EvidenceArtifact` references. The two planes are wired together
by the bundle hash and by nothing else.

## The architectural line

> **Every finding and evaluation pins the bundle that produced it.**

Never evaluate a tenant's compliance against a bundle you constructed by
hand: compile it, activate it, resolve it through the projector's `:bundle`
MFA. The hash on a finding must be traceable to an active `PolicyBundle` row
— that is the audit trail.

## Rules

1. **Only bundles evaluate.** `RuleSetRevision` rows hold `rules_json`, but
   nothing evaluates a revision directly: the lifecycle is draft → validate →
   approve → activate (only `:active` revisions participate in compilation),
   then `compile_policy_bundle` → `activate_policy_bundle`. Activation is
   validate-before-activate — the stored JSON must pass `AshRules.Ir.decode/1`
   in full before it can go live. Revisions are immutable: every save drafts
   a *new* revision; nothing already live is ever overwritten.
2. **The precedence is fixed.** Six ranks, and lower rank wins on conflict:
   `:global_non_waivable` > `:global_mandatory` > `:profile_refinement` >
   `:tenant_strengthening` > `:approved_override` > `:tenant_supplement`
   (`AshCompliance.Compiler.Layer.rank/1` is the single source of the order).
   Non-waivable global rules cannot be waived or replaced by anything; a
   waiver may target any other layer but rides at the override rank, so it
   never outranks its target; a replacement may only displace tenant
   supplements. Do not add "just this once" layer jumps, caller-supplied rule
   lists, or inheritance shortcuts — the compiler refuses overreach and
   weakening that outranks nothing. If a layer's permissions are wrong for a
   program, change the design document first and `Layer` second.
3. **Waivers are bounded, approved and offset.** `expires_at`, `approver` and
   `compensating_controls` (at least one) are validation-enforced. Expiry is
   evaluated against the *compile clock*: an expired waiver is excluded from
   resolution entirely, so a waiver lapsing returns its rule to the effective
   bundle without any action being taken. That is a feature, not a bug to
   suppress.
4. **The finding is the now, the evaluation is the decision.** `Finding` is a
   projection on the grain `[organization_id, control_id, subject_type,
   subject_id]`; `ComplianceEvaluation` is create-only — never updated,
   corrected or deleted. A wrong evaluation is superseded by the next one.
   Never mutate evaluation rows, never fold them into the projection, never
   skip recording one.
5. **Grain changes are migrations.** The finding grain is the identity of
   every projected row; changing it invalidates projections and histories.
   Bump the projector name (blue/green) instead of drifting the grain.
6. **Unknown never becomes compliant.** Do not feed placeholder facts to
   silence `:unknown` findings; fix the fact pipeline or the absence
   semantics. The property lives in `ash_rules` and this package preserves it
   end to end.
7. **Call through `AshCompliance.Domain`.** Every public action is a code
   interface there (`draft_rule_set_revision/2` ... `record_evaluation/2`,
   `active_policy_bundle/2`, the bundle compile/activate/retire lifecycle,
   the OSCAL reads) — hosts and this package's own internals call those,
   never raw `Ash.create!`/`Ash.Query` pipelines.
8. **No API layer.** The package ships resources, actions, the compiler, the
   projector and the editor. Do not add JSON:API/GraphQL surfaces here; the
   host owns exposure and its policies (the package ships no policy blocks,
   and `authorize?:`/`actor:` thread through every domain interface).

## Host wiring checklist

In order, before the first compile of a host that uses this package:

1. **Set the repo in `config/config.exs` — before deps compile.** Resources
   bind `@repo Application.compile_env(:ash_compliance, :repo,
   AshCompliance.TestRepo)` at *compile time*
   (`lib/ash_compliance/resource.ex`; `Finding` repeats it). The default is a
   test-only module: build without the config and every resource silently
   compiles bound to `AshCompliance.TestRepo`, which does not exist in your
   release. `table_prefix` resolves the same way (default
   `"ash_compliance_"`). A runtime `AshCompliance.repo/0` also exists, but
   the compile-time binding is the one that bites.
2. **Register the domain.** Add `AshCompliance.Domain` to the host's
   `ash_domains` (or expose the same code interfaces from a host domain).
3. **Port the migrations.** The suite's `priv/test_repo/migrations` is the
   reference schema for the `ash_compliance_*` tables (plus the projector
   engine's tables); generate or port them into the host's migrations.
4. **No organizations? Use the single-org constant.** Tenancy here is an
   explicit `organization_id` attribute on every row — deliberately not Ash
   multitenancy, so shared catalogs (`organization_id: nil`) stay joinable.
   Org-less hosts mirror the clinic-demo pattern: a module attribute UUID and
   `def organization_id, do: @org`, passed everywhere.
5. **The guard path is sync-only.** Reading the active bundle and evaluating
   it needs no Oban, no projector, no supervisor. Oban is a dev/test-only dep
   here. Add `AshEvents.Projections.Supervisor` to the tree and register a
   projector only when you want findings projected from an event log; test
   the projector synchronously with `AshCompliance.Testing.drain_sync/3`
   (it folds events inside the caller's transaction, outside the async
   Server).

## The guard pattern

Same shape as the `ash_rules` guard pattern (build facts about the
transition, decode the *activated* bundle, evaluate, block on
`[:noncompliant, :unknown, :error]`, inert when no bundle is active, fail
closed when one cannot be evaluated) plus this package's audit half: on a
pass, `record_evaluation/2` runs **after the transaction, best-effort** — a
failed audit row is a logged warning, never a veto of a transition that
legitimately passed. Reference implementation:
`ClinicDemo.Scheduling.Changes.ComplianceGuard` in the clinic-demo host.

## RulesetEditorLive

`use AshCompliance.Web.RulesetEditorLive, domain: ..., organization: ...,
actor: ...` mounts the operator editor: `:domain` is required;
`:organization` is an MFA or literal (a route `:organization_id`/`:org` param
wins; neither raises at mount); `:actor` is an optional MFA threaded through
with `authorize?: true`. The editor edits **structured facts and rules** —
rows for {name, type, one_of, missing semantics} and {name, id, severity,
when_requires/fails_when triples, outcome, gap}, `$name` for a variable —
serialized through `AshRules.Ir.encode!` on save. There is no raw-DSL text
field: what the operator cannot say in the form, the engine cannot be handed.
The toolbar is the lifecycle 1:1 — Draft → Validate → Approve → Activate →
Compile bundle → Activate bundle — each button a thin form over the domain's
own code interface (all hidden forms, so tests drive the whole lifecycle
with `render_submit/2`, no browser). Validate renders the verifier's
diagnostics inline; a rule set that does not verify stays draft.

## Agent integration

`ash_agent_tools` has **no compliance-specific tool**: its optional
integrations are exactly `:ash_rules` (the rules dry-evaluation tool) and
`:ash_state_machine` (the transitions tool) — check
`AshAgentTools.availability/0` for what is active in a given host. This
package's resources are ordinary Ash resources, so agents reach them with
the generic tools: `describe_resource`/`describe_action` for the action
contracts, `semantic_search/2` and `context/3` to find and edit them, and
the `ash_rules` tool to dry-evaluate a bundle before proposing a revision.
(Note for agents: the DSL-level rule set a host edits *in the editor* is
data — propose changes as new revisions through the domain interfaces, never
by rewriting `rules_json` in place.)

## Pin note

Not on Hex. GitHub dependency, and the repository is private:

```elixir
{:ash_compliance, github: "lukegalea/ash_compliance"}
```

`ash_rules` (itself a private GitHub dep) arrives transitively — one PAT
covers both, but CI needs the git rewrite configured before `mix deps.get`
(see this repo's workflow's "Give mix access to private git deps" step).
