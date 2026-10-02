defmodule AshEnterprise.SystemOne.Judgment do
  @moduledoc """
  The judgment ledger: one append-only observation per question per call
  (RFC v0 §5; AST-88 host wiring).

  `AshJudgments.Ledger.Fragment` supplies the attributes, the actions and
  the pure derived-field changes; this resource supplies everything the
  package deliberately does not — the platform base (AshEvents audit,
  tenancy, ownership, provenance columns), the Postgres table and the
  policies. That split is the audit story: AshEvents wraps create, update
  and destroy and never a generic action, so the audit rides the fragment's
  `:record` create and lands in `AshEnterprise.Audit.EventLog` with the
  same tenant and correlation attribution as every other platform write.

  ## Posture

  - **Append-only.** No update exists except the fragment's
    `:tombstone_state` (ADR 0024 erasure: the state payload goes, the
    digests stay, `record_hash` still verifies) — and the erasure is itself
    an audit event. Soft delete is off (`archival?: false`): rows are never
    deleted; re-inference is a new row (law 2). Lifecycle is off: an
    observation has no lifecycle.
  - **Replay-safe by construction** (RFC §6.1). The `:record` create accepts
    every field as input, including the answer; its only changes compute
    pure derived fields (cache key, record hash, region from host config).
    `recorded_at` is the one database-generated field and is declared to
    AshEvents below, so a replay restores it instead of regenerating it.
  - **Tenanted.** Attribute multitenancy on `organization_id` (the platform
    default): the ledger is a tenant-scoped platform resource, and the
    recorder threads the acting tenant through, so a cache lookup is an
    ordinary tenant-scoped read (RFC §4.4 leaves the tenant out of the key
    precisely because of this).

  ## Policies (AC-5, post-AST-136)

  The recorder path and system actors write; nothing else does. The
  `LedgerRecorder` bypass admits the registry's recorder, which marks its
  own calls with the judge hand-off context (the same declared-authority
  pattern as the BPMN and decision engine bypasses — one greppable thing,
  not an anonymous `authorize?: false`); the platform's `SystemActor`
  bypass admits the system actors, while structurally refusing the `ai`
  actor — an attribution label with no authority (ADR 0043, AST-136).
  There is deliberately no `ai` bypass and no person grant path on writes:
  a person never hand-authors an observation. Reads are gated on a role
  grant, exactly like the audit log's own read policy — a judgment reveals
  state digests and model answers, which is evidence, not decoration.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    # An observation is nobody's task and nobody's property: the recorder
    # writes it as system machinery on behalf of the question that was asked.
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.Ledger.Fragment]

  postgres do
    table "system_one_judgments"
    repo AshEnterprise.Repo
  end

  # The fragment's replay contract: `recorded_at` is the one
  # database-generated field, and AshEvents restores it from the event on
  # replay rather than regenerating it (RFC §5.6, §6.1). Merges with the
  # platform base's `event_log` declaration.
  events do
    create_timestamp :recorded_at
  end

  policies do
    # Categorically different from a grant: a system actor is not subject to
    # the role model (see AshEnterprise.Security.Policies). The check
    # structurally refuses the `ai` actor, so model-driven work can never
    # launder itself through this ledger as its own authority (ADR 0043).
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # The judge→recorder hand-off: the recorder passes the judge action's
    # context through, and the check recognises its own caller. Scoped to
    # creates on purpose — the machinery records, it never erases: a
    # `:tombstone_state` update gains nothing from the hand-off and stays
    # an operator act with a named actor.
    bypass AshEnterprise.SystemOne.Checks.LedgerRecorder do
      authorize_if action_type(:create)
    end

    # Same gate as the audit log's read policy (AshEnterprise.Audit.EventLog):
    # a role grant, at whatever depth reaches the row. Tenancy is enforced by
    # the data layer, so a grant is "everything in the tenant", never
    # "everything".
    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end

    # No policy authorizes a write for anyone else: with an authorizer and
    # no grant path, everything above fails closed. A person recording an
    # observation by hand is exactly the rumour-with-a-receipt this ledger
    # exists to prevent.
  end
end
