defmodule AshEnterpriseWeb.A2ui.Judgments.CalibrationUI do
  @moduledoc """
  Every calibration run, newest first (ADR 0061). The surface is
  `AshJudgments.A2ui.Calibration`, bound to this application's
  calibration-run resource. Read-only. Served at
  `/app/judgments/calibration`.
  """
  use AshJudgments.A2ui.Calibration, resource: AshEnterprise.SystemOne.CalibrationRun
end
