defmodule AshEnterprise.SystemOne.CalibrationSample do
  @moduledoc """
  The per-family live calibration accumulation (RFC v0 §8.1; S1-62): one
  append-only row per labelled pair, written AS labelled verdicts occur.

  `AshJudgments.Calibration.SampleFragment` supplies the slot and the
  pair (the gold label itself is payload-class — the row carries digests
  and the observation id); the platform base supplies the audit and
  tenancy. Rows are appended by `HumanVerdict`'s sample-writer change:
  every person verdict whose §7.3 basis feeds calibration
  (`labelling`, `review_task`, `audit_sample`) lands one row — an
  `override` does not (overrides are corrections, not labels). The slot's
  count is the family's n; the n-threshold proposal trigger reads it.

  Writers: the person whose verdict it is (the label's author of record),
  or the system machinery re-appending during replay-safe flows.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.Calibration.SampleFragment]

  postgres do
    table "system_one_calibration_samples"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :added_at
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
