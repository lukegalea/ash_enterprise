defmodule AshEnterpriseWeb.AuditLive do
  @moduledoc """
  `/app/audit` — the Audit trail (`AshEnterpriseWeb.A2ui.AuditUI`): the
  central audit log, newest first, each entry linking to its lineage run.
  One `AshA2ui.LiveRenderer`, read as the signed-in person in their tenant;
  the host chrome is `AshEnterpriseWeb.DailyLive`'s.
  """

  use AshEnterpriseWeb.DailyLive.Surface, ui: AshEnterpriseWeb.A2ui.AuditUI
end
