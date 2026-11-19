defmodule AshEnterpriseWeb.ExportController do
  @moduledoc """
  `GET /api/exports/:type`: one exportable resource as a CSV download, streamed
  in chunks as the rows are read (docs/runbooks/exports.md).

  Behind the bearer pipeline (`:api_csv` in the router), so the caller is the
  person whose API key it is:

    * no key, or a key that does not check out: 401, before anything is read;
    * a person without the export privilege (`AshEnterprise.Exports.Export`): 403;
    * a type that is not exportable (`AshEnterprise.Exports.Csv.types/0`): 404;
    * otherwise 200 and `text/csv`, the rows the person's grants reach in their
      own tenant, read in keyset pages (`AshEnterprise.Exports.Csv.stream/2`).

  Each export is one telemetry span, `[:ash_enterprise, :exports, :csv]`, whose
  metadata is the type and, at the stop, the number of rows written. It carries no
  value, no actor and no tenant: telemetry leaves the zone, the rows must not.
  """

  use AshEnterpriseWeb, :controller

  alias AshEnterprise.Exports.Csv

  @event [:ash_enterprise, :exports, :csv]

  @doc "The telemetry span every export emits."
  @spec event() :: [atom()]
  def event, do: @event

  def show(conn, %{"type" => type}) do
    actor = conn.assigns.current_user

    case AshEnterprise.Exports.open_export(type, actor: actor) do
      {:ok, nil} ->
        refuse(conn, 404, "not_exportable", "Nothing is exportable as #{inspect(type)}.")

      {:ok, resource} ->
        stream(conn, type, resource, actor)

      {:error, %Ash.Error.Forbidden{}} ->
        refuse(conn, 403, "forbidden", "Exporting needs the export privilege.")
    end
  end

  defp stream(conn, type, resource, actor) do
    tenant = Ash.PlugHelpers.get_tenant(conn)

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{type}.csv"))
      |> send_chunked(200)

    :telemetry.span(@event, %{type: type}, fn ->
      {conn, rows} =
        resource
        |> Csv.stream(actor: actor, tenant: tenant)
        |> Stream.chunk_every(Csv.batch_size())
        |> Enum.reduce_while({conn, -1}, &send_page/2)

      {conn, %{type: type, rows: max(rows, 0)}}
    end)
  end

  # One keyset page of lines, one chunk. The count starts at -1 for the header.
  defp send_page(lines, {conn, rows}) do
    case chunk(conn, lines) do
      {:ok, conn} -> {:cont, {conn, rows + length(lines)}}
      # The client went away: stop reading.
      {:error, _closed} -> {:halt, {conn, rows}}
    end
  end

  defp refuse(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end
end
