defmodule AshEnterpriseWeb.A2ui.Judgments.BandTablesUI do
  @moduledoc """
  Band tables a calibration run proposed and no one has certified yet
  (ADR 0061). The surface is `AshJudgments.A2ui.BandTables`, bound to this
  application's calibration-run resource. The button runs `:certify_now`: the
  person's own request for the governed `:certify_and_publish`
  (`AshEnterprise.SystemOne.BandTablePublication.CertifyAndPublish`), which
  they confirm in the same click (`AshEnterprise.Execution.Actions.ConfirmInvocation`).
  Served at `/app/judgments/band-tables`.
  """
  use AshJudgments.A2ui.BandTables,
    resource: AshEnterprise.SystemOne.CalibrationRun,
    certify_action: :certify_now
end
