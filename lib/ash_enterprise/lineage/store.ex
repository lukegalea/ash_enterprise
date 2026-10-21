defmodule AshEnterprise.Lineage.Store do
  @moduledoc """
  Keeps the RunEvents the transport hands it, for the Lineage app.

  `record/2` is called from the process that made the write (the notifier
  runs there, after the transaction commits). What it does depends on the
  configured mode:

      config :ash_enterprise, AshEnterprise.Lineage.Store,
        mode: :buffered,          # :buffered | :inline | :off
        flush_interval_ms: 1_000,
        max_batch: 500,
        max_buffer: 20_000

    * `:buffered` (dev, prod) — one `GenServer.cast/2` to this process,
      which collects events and writes them every `flush_interval_ms`, or
      as soon as `max_batch` are waiting. A Gmail sync that lands 200
      messages emits about a thousand COMPLETE events (one per row
      written); they arrive here as a thousand casts and leave as one write
      of a handful of rows, because the events of one run coalesce
      (`AshEnterprise.Lineage.Recorder`). Past `max_buffer` waiting events,
      new ones are dropped and counted in a warning: lineage is telemetry,
      and a flood must not grow this process without bound.
    * `:inline` — written in the caller's process, immediately. For tests,
      which need the rows inside their own sandbox transaction.
    * `:off` — dropped. The test default: most tests write rows, and none of
      them is about lineage.

  A process is the right tool here because it batches across callers (Iron
  Law #13): the coalescing only pays when a thousand events from many
  processes share one write. What is buffered when the node stops is
  flushed in `terminate/2`; a crash loses the buffer, which is the price of
  keeping lineage off every write's path.
  """

  use GenServer

  require Logger

  alias AshEnterprise.Lineage.Recorder

  @defaults [mode: :buffered, flush_interval_ms: 1_000, max_batch: 500, max_buffer: 20_000]

  @doc "Records one RunEvent with its host metadata, per the configured mode. Always `:ok`."
  @spec record(map(), map()) :: :ok
  def record(event, meta) when is_map(event) do
    entry = {event, normalize_meta(meta)}

    case config(:mode) do
      :off ->
        :ok

      :inline ->
        Recorder.write([entry])
        :ok

      :buffered ->
        GenServer.cast(__MODULE__, {:record, entry})
    end
  end

  @doc "Writes whatever the buffered process holds now. Returns the write's summary."
  @spec flush(GenServer.server()) :: Recorder.summary()
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    settings =
      @defaults
      |> Keyword.merge(Application.get_env(:ash_enterprise, __MODULE__, []))
      |> Keyword.merge(Keyword.take(opts, Keyword.keys(@defaults)))

    {:ok, %{buffer: [], size: 0, dropped: 0, timer: nil, settings: settings}}
  end

  @impl true
  def handle_cast({:record, entry}, %{size: size, settings: settings} = state) do
    cond do
      size >= settings[:max_buffer] ->
        {:noreply, %{state | dropped: state.dropped + 1}}

      size + 1 >= settings[:max_batch] ->
        {:noreply, write(%{state | buffer: [entry | state.buffer], size: size + 1})}

      true ->
        {:noreply, arm(%{state | buffer: [entry | state.buffer], size: size + 1})}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {summary, state} = write_with_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, write(%{state | timer: nil})}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp arm(%{timer: nil, settings: settings} = state),
    do: %{state | timer: Process.send_after(self(), :flush, settings[:flush_interval_ms])}

  defp arm(state), do: state

  defp write(state) do
    {_summary, state} = write_with_summary(state)
    state
  end

  defp write_with_summary(%{buffer: []} = state), do: {Recorder.empty_summary(), state}

  defp write_with_summary(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.dropped > 0 do
      Logger.warning("AshEnterprise.Lineage: dropped #{state.dropped} events past max_buffer")
    end

    summary =
      try do
        state.buffer |> Enum.reverse() |> Recorder.write()
      rescue
        exception ->
          Logger.warning(
            "AshEnterprise.Lineage: a write of #{state.size} events failed: " <>
              inspect(exception.__struct__)
          )

          Recorder.empty_summary()
      end

    {summary, %{state | buffer: [], size: 0, dropped: 0, timer: nil}}
  end

  defp config(key) do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, @defaults[key])
  end

  # The tenant arrives as whatever the write was made under: an organization
  # id, or a struct carrying one. Only the id is kept.
  defp normalize_meta(meta) when is_map(meta) do
    %{tenant: tenant_id(meta[:tenant]), linked_account_id: meta[:linked_account_id]}
  end

  defp normalize_meta(_meta), do: %{tenant: nil, linked_account_id: nil}

  defp tenant_id(nil), do: nil
  defp tenant_id(tenant) when is_binary(tenant), do: tenant
  defp tenant_id(%{id: id}) when is_binary(id), do: id
  defp tenant_id(_other), do: nil
end
