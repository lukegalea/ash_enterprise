defmodule AshEnterprise.SystemOne.HumanVerdict do
  @moduledoc """
  The human verdict ledger: a person's confirmation or correction of a
  recorded observation (RFC v0 §7.3; AST-88 host wiring).

  `AshJudgments.HumanVerdict.Fragment` supplies the fields and the
  `:record` create — the reviewer is an *input* (the author of record; the
  model-answer snapshot, the blind-labelling flag and the basis ride
  alongside) so AshEvents replay rebuilds the row from its inputs alone.
  This resource supplies the platform base and the policies.

  ## Posture

  - **Person writes.** The one thing a verdict must be is a judgement
    somebody actually made, so the create authorizes a person actor and
    nothing else — no system-actor bypass, and therefore no `ai` actor
    either (ADR 0043, AST-136: model-driven work never fabricates a human
    judgement). Which reviewer identity a given person may claim is grant
    data that lands with the review-task work; the row already records who
    claimed it.
  - **Replay-safe.** Every field is an input; there is nothing to derive.
    Replay re-runs creates with authorization off inside AshEvents, so the
    person-only policy cannot strand a rebuild.
  - **Audited.** The create is an AshEvents event like every platform write,
    attributed to its tenant and correlation group. The `reason` field is
    the one payload-class field (a reviewer's free text can quote a
    document, RFC §9); everything else is ids, digests and codes.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.HumanVerdict.Fragment]

  postgres do
    table "system_one_human_verdicts"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :recorded_at
  end

  changes do
    # The live-calibration wiring (S1-62): a labelled verdict feeds the
    # family's accumulation slot as it lands — §7.3 basis routing inside
    # the change (labelling/review_task/audit_sample feed; overrides do
    # not). An after_action hook: AshEvents strips hooks during replay,
    # so a replayed verdict appends nothing.
    change {AshEnterprise.SystemOne.Banding.CalibrationSampleWriter, []}, on: :create
  end

  policies do
    # A verdict is a person's judgement (see the module doc). The check is
    # positive — "is a user row" — so a future actor kind fails closed
    # rather than being admitted by omission.
    policy action_type(:create) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    # Reads follow the platform convention: a role grant, at whatever depth
    # reaches the row; tenancy is the data layer's job. Verdicts are the
    # evaluation corpus — reviewed data is biased (ADR 0047 point 8) — so
    # they are evidence, gated like the audit log's own reads.
    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
