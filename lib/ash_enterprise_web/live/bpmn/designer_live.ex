defmodule AshEnterpriseWeb.Bpmn.DesignerLive do
  @moduledoc """
  The BPMN designer, for the process named in the route.

  No compile-time `:process`: the key comes from `:key` in the path, so one module serves every
  process this application ships and every process a tenant authors for itself.

  What is drawn here is edited *in the tenant's own scope*, which is what makes customization
  safe without a permission model of its own — a tenant admin physically cannot write a
  definition into another tenant, and baselines are unreachable from the web entirely
  (`mix ash_enterprise.bpmn.publish` is the only way in).
  """

  use AshBpmn.Web.DesignerLive,
    domain: AshEnterprise.Bpmn,
    actor: {AshEnterpriseWeb.Bpmn.Helpers, :current_actor, []}
end
