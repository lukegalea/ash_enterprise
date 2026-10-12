defmodule AshEnterprise.Integration.Landing.NotWired do
  @moduledoc """
  The lander used when none is configured: persists nothing. Provider content
  must never land outside an erasure scope, so a deployment that has not named
  a lander (`config :ash_enterprise, AshEnterprise.Integration.Landing,
  lander: AshEnterprise.Integration.Landing.Scoped`) refuses every landing and
  every vertical refuses to fetch. See `AshEnterprise.Integration.Landing`.
  """

  @behaviour AshEnterprise.Integration.Landing

  @impl true
  def land(_record, _scope), do: {:error, :scoped_landing_not_wired}
end
