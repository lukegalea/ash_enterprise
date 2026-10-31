defmodule AshEnterpriseWeb.A2ui.Judgments.CertificationsUI do
  @moduledoc """
  The band tables in force, with who certified them (ADR 0061). The
  surface is `AshJudgments.A2ui.Certifications`, bound to this
  application's certification resource. The button runs `:revoke_now`: the
  person's own request for the governed `:revoke`, which they confirm in the
  same click. Served at
  `/app/judgments/certifications`.
  """
  use AshJudgments.A2ui.Certifications,
    resource: AshEnterprise.SystemOne.BandTableCertification,
    revoke_action: :revoke_now
end
