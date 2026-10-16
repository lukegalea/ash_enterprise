defmodule AshEnterprise.Mdm.ManualCsvAdapter do
  @moduledoc """
  The adapter for the `:manual_csv` source in `AshEnterprise.Mdm.Landing`.

  The source is push-only: a CS upload lands each row through
  `AshEnterprise.Mdm.Landing.land_row/4`, and there is nothing to pull.
  The module implements `AshDiscreteBusinessEvents.Adapters.Adapter`
  because bizev refuses to compile a source whose adapter does not
  conform; `fetch_batch/5` returns an error rather than an empty page, so
  a sync accidentally pointed at this source fails visibly.
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  @impl true
  def cursor_field(_stream), do: "fetched_at"

  @impl true
  def fetch_batch(_source, _stream, _conn, _cursor, _opts),
    do: {:error, :push_only_source}

  @impl true
  def api_calls_per_batch, do: 1
end
