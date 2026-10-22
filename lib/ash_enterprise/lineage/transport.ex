defmodule AshEnterprise.Lineage.Transport do
  @moduledoc """
  The host's OpenLineage transport: every platform resource's, and the one
  `AshOpenLineage.emit/2`/`fail/3` use (`config :ash_open_lineage, :transport`).

  Each RunEvent goes to two places:

    1. `AshEnterprise.Lineage.Store`, which keeps it for the Lineage app. The
       store buffers off the caller's path (`:buffered`, the default), so a
       write pays one message send for its lineage, not a database round
       trip.
    2. An OpenLineage HTTP backend (Marquez, DataHub), **only** when
       `config :ash_open_lineage, :http_base_url` is set. The POST runs under
       the platform's `Task.Supervisor`: 440 landed rows must not cost 440
       sequential round trips inside a tap run, and a failed POST is logged
       and dropped — the audit log, not the catalogue, is the record of
       consequence.

  The host metadata `send/2` receives (the write's tenant, and for a sync the
  linked account) decides which tenant's run the event belongs to. It is
  never written into the event and never sent to the backend.

  Never raises: a lineage failure must not take a write down with it.
  """

  @behaviour AshOpenLineage.Transport

  import Kernel, except: [send: 2]

  require Logger

  @impl true
  def send(event), do: send(event, %{})

  @impl true
  def send(event, meta) do
    try do
      AshEnterprise.Lineage.Store.record(event, meta)
    rescue
      exception ->
        Logger.warning(
          "AshEnterprise.Lineage: the store dropped an event: #{inspect(exception.__struct__)}"
        )
    end

    if Application.get_env(:ash_open_lineage, :http_base_url) do
      Task.Supervisor.start_child(AshEnterprise.TaskSupervisor, fn -> post(event) end)
    end

    :ok
  end

  defp post(event) do
    case AshOpenLineage.Transport.Req.send(event) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("AshOpenLineage: transport dropped event: #{inspect(error)}")
    end
  end
end
