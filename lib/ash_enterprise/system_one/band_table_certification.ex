defmodule AshEnterprise.SystemOne.BandTableCertification do
  @moduledoc """
  The judgment-side half of band-table certification (RFC v0 §8.2; AST-92
  host wiring): which band-table definition is fit for which question
  family, on what calibration evidence, certified by whom.

  `AshJudgments.Banding.CertificationFragment` supplies the record; the
  platform base supplies the audit and tenancy. Revocation is a new row
  with `status: :revoked` — certifications are superseded, never edited.
  Activation itself stays `ash_decisions`' lifecycle; this record is the
  judgment-side provenance the RFC's §8.2 chain hangs from
  (certification → calibration run → evaluation-set hash).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.SystemOne,
    ownership: :none,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    fragments: [AshJudgments.Banding.CertificationFragment]

  postgres do
    table "system_one_band_table_certifications"
    repo AshEnterprise.Repo
  end

  events do
    create_timestamp :certified_at
  end

  policies do
    # Certifying is a person's professional act (the author of record is
    # an input); revoking likewise. System machinery neither certifies nor
    # revokes.
    policy action_type([:create, :update]) do
      authorize_if AshEnterprise.SystemOne.Checks.PersonActor
    end

    policy action_type(:read) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
