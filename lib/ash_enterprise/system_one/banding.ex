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

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
