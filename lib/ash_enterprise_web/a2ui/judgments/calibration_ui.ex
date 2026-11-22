defmodule AshEnterpriseWeb.A2ui.Judgments.CalibrationUI do
  @moduledoc """
  Every calibration run, newest first, with the share of its items its
  table decides without review (ADR 0061). Beside them, the **Automated
  share** report: per family and week, the live bandings the table
  admitted, sent to review and omitted (`CalibrationRun`'s
  `:automated_share`). The surface is `AshJudgments.A2ui.Calibration`,
  bound to this application's calibration-run resource. Read-only. Served
  at `/app/judgments/calibration`.
  """
  use AshJudgments.A2ui.Calibration,
    resource: AshEnterprise.SystemOne.CalibrationRun,
    share_action: :automated_share
end
