defmodule AshEnterprise.Integration.Landing.NotWired do
  @moduledoc """
  The default lander: persists nothing. Scoped (crypto-shreddable) landing is
  not wired yet, and provider content must not land unencrypted in the
  meantime. See `AshEnterprise.Integration.Landing`.
  """

  @behaviour AshEnterprise.Integration.Landing

  @impl true
  def land(_record, _scope_ref), do: {:error, :scoped_landing_not_wired}
end
