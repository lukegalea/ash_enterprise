defmodule AshEnterprise.Exports.Csv do
  @moduledoc """
  One exportable resource as CSV, streamed: the header, then a line per row, read
  in keyset pages so the set is never held in memory.

  ## What is exportable

  The resources this application exposes over JSON:API and GraphQL (`api_type`),
  through the paged `:list` read the API serves, named as their JSON:API route
  names them. The list is declared here, not derived: a resource joins the bulk
  export by a reviewed line, the way it joins the API by one. Today that is
  business units, teams and positions. "Any resource" means any resource on this
  list, and the list is what the ledger cites.

  ## Scoping

  The read runs as the requester, in their tenant, through the resource's own
  policies, as `AshEnterprise.Audit.Export` does for the audit log: a person
  exports exactly the rows their grants reach and nothing else. The columns are
  the resource's public attributes, the ones the API serves. A cell a field
  policy withholds from the reader (`Ash.ForbiddenField`) is written empty.

  ## Spreadsheet formulas

  A text cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is
  written with a leading `'`, so a spreadsheet opening the file shows it as text
  instead of evaluating it (CSV formula injection). Numbers, dates and booleans are
  written as they are.
  """

  alias AshEnterprise.Accounts.{BusinessUnit, Position, Team}

  @exportable %{
    "business_units" => BusinessUnit,
    "positions" => Position,
    "teams" => Team
  }

  # The `:list` read caps a page at 250 (`max_page_size`); a stream page is one of them.
  @read_action :list
  @batch_size 250

  @formula_leads ["=", "+", "-", "@", "\t", "\r"]

  @doc "The exportable types, sorted."
  @spec types() :: [String.t()]
  def types, do: @exportable |> Map.keys() |> Enum.sort()

  @doc "The resource `type` names, or nil when it is not exportable."
  @spec resource_for(String.t()) :: module() | nil
  def resource_for(type), do: Map.get(@exportable, type)

  @doc "How many rows a stream page reads."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc "The exported columns of `resource`, in header order: its public attributes."
  @spec columns(module()) :: [atom()]
  def columns(resource),
    do: resource |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

  @doc """
  The CSV of `resource` as a stream of lines, header first, each ending in CRLF.

  Options: `:actor` and `:tenant` (required: the read is the requester's) and
  `:batch_size` (rows per keyset page, at most #{@batch_size}).
  """
  @spec stream(module(), keyword()) :: Enumerable.t()
  def stream(resource, opts) do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.fetch!(opts, :tenant)
    columns = columns(resource)

    header = [line(Enum.map(columns, &Atom.to_string/1))]

    rows =
      resource
      |> Ash.Query.for_read(@read_action, %{}, actor: actor, tenant: tenant)
      |> Ash.Query.select(columns)
      |> Ash.stream!(batch_size: Keyword.get(opts, :batch_size, @batch_size))
      |> Stream.map(fn record -> line(Enum.map(columns, &cell(Map.get(record, &1)))) end)

    Stream.concat(header, rows)
  end

  @doc false
  # One CSV line from cells already turned to text: RFC 4180 quoting.
  @spec line([String.t()]) :: String.t()
  def line(cells), do: Enum.map_join(cells, ",", &quote_cell/1) <> "\r\n"

  @doc false
  # One value as the text of its cell. Public so a test can hold the cell contract.
  @spec cell(term()) :: String.t()
  def cell(nil), do: ""
  def cell(%Ash.ForbiddenField{}), do: ""
  def cell(%Ash.NotLoaded{}), do: ""
  def cell(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def cell(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def cell(%Ash.CiString{} = value), do: value |> to_string() |> text()
  def cell(value) when is_binary(value), do: text(value)
  def cell(value) when is_boolean(value) or is_atom(value), do: Atom.to_string(value)
  def cell(value) when is_number(value), do: to_string(value)
  def cell(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def cell(%Date{} = value), do: Date.to_iso8601(value)
  def cell(%Time{} = value), do: Time.to_iso8601(value)
  def cell(value) when is_map(value) or is_list(value), do: value |> Jason.encode!() |> text()

  defp text(value) do
    if String.starts_with?(value, @formula_leads), do: "'" <> value, else: value
  end

  defp quote_cell(cell) do
    if String.contains?(cell, [",", "\"", "\r", "\n"]) do
      "\"" <> String.replace(cell, "\"", "\"\"") <> "\""
    else
      cell
    end
  end
end
