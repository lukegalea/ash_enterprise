defmodule AshEnterpriseWeb.A2ui.DeliveriesUI do
  @moduledoc """
  Provider webhook deliveries: what providers have sent, newest first, with the signature
  verdict and whether anyone followed up. The surface is `AshOperations.A2ui.Deliveries`, bound
  to this application's delivery resource
  (`AshEnterprise.Integration.Operations.Delivery`). Read-only: a delivery is a nudge that
  carries no body and no header, and the follow-up is the `oban` system actor's, so the surface
  offers no reconcile action. Served at `/app/deliveries` behind the `:operator` door.
  """

  use AshOperations.A2ui.Deliveries,
    resource: AshEnterprise.Integration.Operations.Delivery
end
