defmodule AshEnterpriseWeb.A2ui.Judgments.FactsUI do
  @moduledoc """
  The facts current now, per subject and predicate (ADR 0061). The surface
  is `AshJudgments.A2ui.Facts`, bound to this application's facts
  resource. Read-only. Served at `/app/judgments/facts`.
  """
  use AshJudgments.A2ui.Facts, resource: AshEnterprise.SystemOne.Fact
end
