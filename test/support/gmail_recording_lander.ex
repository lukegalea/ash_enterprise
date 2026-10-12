defmodule AshEnterprise.Test.GmailRecordingLander do
  @moduledoc """
  A test lander (`AshEnterprise.Integration.Landing`): records every `land/2`
  call in a named Agent instead of persisting anything. Start it with
  `start_supervised!(AshEnterprise.Test.GmailRecordingLander)` and point
  `config :ash_enterprise, AshEnterprise.Integration.Landing, lander:` at this
  module.
  """

  @behaviour AshEnterprise.Integration.Landing

  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @impl AshEnterprise.Integration.Landing
  def land(record, scope_ref) do
    Agent.update(__MODULE__, &[{record, scope_ref} | &1])
    {:ok, :recorded}
  end

  @doc "Every landing, oldest first."
  def landings, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()

  @doc "The external ids landed, oldest first."
  def landed_ids, do: Enum.map(landings(), fn {record, _scope} -> record.external_id end)
end
