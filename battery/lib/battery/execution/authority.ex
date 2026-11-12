defmodule Battery.Execution.Authority do
  @moduledoc """
  The battery's `AshAgent.Approval.Authority`: every tenant is on the `:standard`
  posture, so four eyes holds as declared. The battery proves the substrates meet,
  not the posture rules, which `ash_agent` and the host's own suite cover. Nobody
  is answered as a role holder or an operator, so nothing here widens who decides.
  """

  @behaviour AshAgent.Approval.Authority

  @impl true
  def posture(_tenant), do: {:standard, nil}

  @impl true
  def holders(_tenant, _role), do: []

  @impl true
  def administrator_role, do: :administrator

  @impl true
  def operator?(_actor), do: false
end
