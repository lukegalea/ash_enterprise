defmodule AshEnterprise.SystemOne.EvidenceAssertion do
  @moduledoc """
  The evidence assertion: the aggregate evidence verdict one packet's
  adjudication produced — the admission's provenance (RFC v2 Q15 ruling,
  shape (a): a separate assertion record; AST-152 host wiring).

  `AshEvidence.Assertions.Fragment` supplies the record — every field an
  input, `record_hash` the one pure derived change, the disposition in the
  frozen §5.5 vocabulary, the distribution as decimal strings, and the
  admission handoff keys (`subject`, `predicate`, `subject_state_digest`,
  `question_set_hash`). This resource supplies the platform base — AshEvents
  audit, tenancy, provenance columns — so an assertion is an attributed audit
  event like every platform write, exactly as the banding is (the d582f88
  pattern).

  ## Envelope-class, and why it has no foreign keys

  The packet, evaluation and candidate sets it cites are blob-class: they
  cascade away with their document version (erasure linkage). The assertion
  SURVIVES erasure — every field is an id, a digest, a frozen-vocabulary
  atom or a decimal string, so after the cited records are gone it reads as
  references to things that no longer resolve, and `record_hash` still
  verifies, because nothing hashed was ever payload class.

  ## Replay safety (AC-2)

  The `:record` create accepts every field as input; its only change
  (`DeriveRecord`, from the fragment) computes `record_hash` from the
  inputs — pure, identical on replay, no I/O, no clock. The aggregation ran
  in the orchestrator BEFORE the create; nothing instrument-shaped exists
  anywhere on this path, so an AshEvents replay rebuilds the row
  byte-identically with zero model calls. `created_at` is the one
  database-generated field and is declared to AshEvents below, so a replay
  restores it instead of regenerating it (the ledger's `recorded_at`
  pattern).

  Policies follow the banding's posture: adjudication is machinery — the
  orchestrator records as a system actor and nothing else may write (the
  `ai` label has no path and no bypass, ADR 0043/AST-136); reads are
  role-gated like the audit log's.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshEvidence.Assertions.Fragment]

  postgres do
    table "system_one_evidence_assertions"
    repo AshEnterprise.Repo
  end

  events do
    # The fragment's replay contract: `created_at` is the one
    # database-generated field, restored from the event on replay (RFC §6.1).
    # Merges with the platform base's `event_log` declaration.
    create_timestamp :created_at
  end

  policies do
    # Categorically different from a grant: a system actor is not subject to
    # the role model. The check structurally refuses the `ai` actor — model
    # work can never launder itself through the assertion record as its own
    # authority (ADR 0043).
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # Same gate as the audit log's read policy: a role grant, at whatever
    # depth reaches the row. Tenancy is enforced by the data layer.
    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
