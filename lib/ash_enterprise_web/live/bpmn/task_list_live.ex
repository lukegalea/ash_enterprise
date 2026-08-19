defmodule AshEnterpriseWeb.Bpmn.TaskListLive do
  @moduledoc """
  Approvals waiting on the signed-in person.

  One indexed query, joined on the actor's principal ids, because candidacy is materialised as
  rows rather than evaluated per record. That is the performance half of
  `docs/manifesto/03-authorization-is-data.md`, and it is why this page does not get slower as
  the role model grows.
  """

  use AshBpmn.Web.TaskListLive,
    domain: AshEnterprise.Bpmn,
    principal_ids: {AshEnterpriseWeb.Bpmn.Helpers, :current_principal_ids, []}
end
