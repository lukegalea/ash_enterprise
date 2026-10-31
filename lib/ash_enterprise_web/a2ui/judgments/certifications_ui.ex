defmodule AshEnterpriseWeb.A2ui.Judgments.CertificationsUI do
  @moduledoc """
  The band tables in force, with who certified them (ADR 0061). The
  surface is `AshJudgments.A2ui.Certifications`, bound to this
  application's certification resource; revoking is person-only. Served at
  `/app/judgments/certifications`.
  """
  use AshJudgments.A2ui.Certifications, resource: AshEnterprise.SystemOne.BandTableCertification
end
