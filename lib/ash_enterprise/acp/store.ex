defmodule AshEnterprise.Acp.Store do
  @moduledoc """
  Supervised owner of the ACP session ETS table (epic E3). Table
  ownership must not follow a transient handler process, or the table dies
  with the first session that created it.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    AshEnterprise.Acp.ensure_tables!()
    {:ok, %{}}
  end
end
