defmodule AshEnterpriseWeb.A2ui.Judgments.BandTablesUI do
  @moduledoc """
  Band tables a calibration run proposed and no one has certified yet
  (ADR 0061). The surface is `AshJudgments.A2ui.BandTables`, bound to this
  application's calibration-run resource; certifying is the run's
  person-only `:certify_and_publish`
  (`AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish`).
  Served at `/app/judgments/band-tables`.
  """
  use AshJudgments.A2ui.BandTables, resource: AshEnterprise.SystemOne.CalibrationRun
end
