defmodule Battery.BusinessEvents.StubAdapter do
  @moduledoc """
  A conformance-complete stand-in adapter for the battery's sources. It
  never fetches anything — the battery lands SourceRecords directly through
  `land/1` (the typed boundary); sync runs are the adapter's own suite's
  business.
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  @impl true
  def cursor_field(_stream), do: "SystemModstamp"

  @impl true
  def fetch_batch(_source, _stream, _conn, _cursor, _opts) do
    {:error, "the battery stub adapter fetches nothing"}
  end

  @impl true
  def api_calls_per_batch, do: 1
end
