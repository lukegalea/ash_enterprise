defmodule AshEnterprise.Telemetry.OtlpIngest.Limiter do
  @moduledoc false

  # A fixed-window counter per key. Long-lived on purpose: the ETS table must
  # outlive any request process, or a request's exit would take the counts with it.

  use GenServer

  @table :ash_enterprise_telemetry_ingest_limiter
  @window_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Records one request for `key`; false once `limit` is exceeded this minute."
  @spec allow?(term(), non_neg_integer(), atom()) :: boolean()
  def allow?(key, limit, table \\ @table) do
    count = :ets.update_counter(table, {window(), key}, 1, {{window(), key}, 0})
    count <= limit
  rescue
    # No table means the owner is restarting. Reject rather than admit unmetered.
    ArgumentError -> false
  end

  defp window, do: div(System.system_time(:millisecond), @window_ms)

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_purge()
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:purge, state) do
    current = window()
    :ets.select_delete(@table, [{{{:"$1", :_}, :_}, [{:<, :"$1", current}], [true]}])
    schedule_purge()
    {:noreply, state}
  end

  defp schedule_purge, do: Process.send_after(self(), :purge, @window_ms)
end
