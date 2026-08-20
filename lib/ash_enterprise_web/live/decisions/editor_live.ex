defmodule AshEnterpriseWeb.Decisions.EditorLive do
  @moduledoc """
  The DMN decision editor, for the decision named in the route.

  The counterpart to `AshEnterpriseWeb.Bpmn.DesignerLive`, and it holds the same line: no
  compile-time key, so one module serves every decision this application ships as a baseline
  and every decision a tenant forks for itself.

  Editing happens in the tenant's own scope, which is what makes per-tenant decision logic safe
  without a second permission model — a tenant admin cannot write a definition into another
  tenant, and the platform baselines are unreachable from the web at all. Publishing a baseline
  is `mix ash_enterprise.bpmn.publish` running as a system actor against reviewed artifacts in
  `priv/dmn/`, for the reason ADR 0029 gives: a decision that governs who may approve what is a
  reviewed artifact, not a form submission.
  """

  use AshDecisions.Web.EditorLive,
    domain: AshEnterprise.Decisions,
    actor: {AshEnterpriseWeb.Bpmn.Helpers, :current_actor, []}
end
