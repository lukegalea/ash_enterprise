defmodule AshEnterprise.Finance.Tiller.Adapter do
  @moduledoc """
  The BIZEV adapter for the `:tiller` source
  (`AshEnterprise.Finance.Declarations`): one exchange per stream reads the
  whole tab through Google Sheets (`AshEnterprise.Integration.GoogleSheets`,
  Nango at the auth edge only, ADR 0011) and returns its rows as the sheet
  emitted them, read by header (`AshEnterprise.Finance.Tiller.Rows.table/1`).
  Interpretation is the mappings' job, never the adapter's.

  ## The conn

  Not a token: the actor whose linked account it is, and which account and
  sheet. The Sheets action resolves the Nango connection from that actor's
  own linked accounts, under their policies; nothing here ever holds a
  connection id or a credential.

      %{actor: actor, linked_account_id: id, spreadsheet_id: id,
        ranges: %{transactions: "Transactions", balance_history: "Balance History"}}

  ## No cursor

  The Sheets API has no change feed for cell values, and a Tiller sheet is a
  few thousand rows, so every exchange reads the whole tab
  (`complete?: true`, `next_cursor: nil`). What changed is decided where it
  lands: an unchanged row lands as nothing (`AshEnterprise.Finance.Tiller.Step`).

  ## Not through `Adapters.Sync.run/1`

  BIZEV's sync template lands each record in the clear, keyed on a
  Salesforce `"Id"`. A Tiller row must land sealed under its linked
  account's erasure scope and keyed by `Rows`, so the finance step drives
  this adapter itself (see the step's moduledoc, and the PROD-12 report on
  what should move into the package).
  """

  @behaviour AshDiscreteBusinessEvents.Adapters.Adapter

  alias AshEnterprise.Finance.Tiller.Rows
  alias AshEnterprise.Integration.GoogleSheets

  @impl true
  def cursor_field(_stream), do: "fetched_at"

  @impl true
  def api_calls_per_batch, do: 1

  @impl true
  def fetch_batch(_source, %{name: stream}, conn, _cursor, _opts) do
    with {:ok, range} <- Map.fetch(conn.ranges, stream),
         {:ok, body} <-
           GoogleSheets.batch_get_values(
             %{
               spreadsheet_id: conn.spreadsheet_id,
               ranges: [range],
               value_render_option: "UNFORMATTED_VALUE",
               date_time_render_option: "SERIAL_NUMBER",
               major_dimension: "ROWS",
               linked_account_id: conn.linked_account_id
             },
             actor: conn.actor
           ),
         {:ok, values} <- values(body) do
      {:ok, headers, rows} = Rows.table(values)

      {:ok,
       %{
         records: rows,
         headers: headers,
         next_cursor: nil,
         complete?: true,
         api_calls_used: 1
       }}
    else
      :error -> {:error, :unknown_stream}
      {:error, _} = error -> error
    end
  end

  # One range requested, so one value range back. A tab with nothing in it
  # comes back without `values`.
  defp values(%{"valueRanges" => [%{} = range]}), do: {:ok, Map.get(range, "values", [])}
  defp values(_body), do: {:error, :unexpected_response}
end
