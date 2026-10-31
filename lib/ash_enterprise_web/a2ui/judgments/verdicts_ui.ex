defmodule AshEnterpriseWeb.A2ui.Judgments.VerdictsUI do
  @moduledoc """
  Judgments the band table sent to review, awaiting a person's verdict
  (ADR 0061). The surface is `AshJudgments.A2ui.Verdicts`, bound to this
  application's banding resource; recording a verdict is the banding's
  person-only `:record_verdict`. Served at `/app/judgments`.
  """
  use AshJudgments.A2ui.Verdicts, resource: AshEnterprise.SystemOne.Banding
end
