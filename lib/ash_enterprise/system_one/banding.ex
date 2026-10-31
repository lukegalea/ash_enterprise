defmodule AshEnterprise.SystemOne.Banding do
  @moduledoc """
  The banding record: which band-table row a judged answer fell into
  (RFC v0 §7.1; AST-92 host wiring).

  `AshJudgments.Banding.Fragment` supplies the record (every field an
  input, `record_hash` derived, `matched_rule_ids` empty refused at the
  boundary); this resource supplies the platform base — AshEvents audit,
  tenancy, provenance columns — so a banding is an attributed audit event
  like every platform write. `AshEnterprise.SystemOne.Banding.Step` is the
  host pipeline that runs before it: flatten → resolve → evaluate →
  record → route, per RFC §6.1 (the band-table evaluation happens before
  the create; its outputs arrive as inputs).

  Policies follow the ledger's posture: banding is machinery — the step
  runs as a system actor and nothing else may write (the `ai` label has
  no path and no bypass, ADR 0043/AST-136); reads are role-gated like the
  audit log's.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    extra_extensions: [AshAgent.Effects],
    fragments: [AshJudgments.Banding.Fragment]

  postgres do
    table "system_one_bandings"
    repo AshEnterprise.Repo
  end

  events do
    # The fragment's replay contract: `banded_at` is the one
    # database-generated field, restored from the event on replay.
    create_timestamp :banded_at
  end

  # The verdicts surface's contract (AshJudgments.A2ui.Verdicts, ADR 0061).
  actions do
    read :awaiting_verdict do
      description "Bandings in the review band with no person's verdict for any of their observations."

      filter expr(
               band == :review and
                 not exists(
                   AshEnterprise.SystemOne.HumanVerdict,
                   judgment_id in parent(observation_ids)
                 )
             )

      prepare build(sort: [banded_at: :asc])
    end

    action :record_verdict, :map do
      description "A person's verdict on a review-banded judgment: one HumanVerdict per observation."
      argument :record_id, :uuid, allow_nil?: false
      argument :value, :string, allow_nil?: false
      argument :reason, :string

      run {AshJudgments.HumanVerdict.FromBanding,
           verdict_resource: AshEnterprise.SystemOne.HumanVerdict,
           judgment_resource: AshEnterprise.SystemOne.Judgment}
    end
  end

  # A verdict is the person confirming their own answer on the surface (ADR 0057). The person confirms by clicking; an agent's request for it is
  # S1-78's governed path.
  effects do
    action :record_verdict,
      kind: :execute,
      open_world?: false,
      approval: :confirm,
      intent: :approve
  end

  policies do
    # A verdict is a person's act (ADR 0059). It comes before the bypass,
    # which covers only the policies after it.
    policy action(:record_verdict) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
