defmodule AshEnterprise.Audit.Export do
  @moduledoc """
  The audit log as a file an auditor can open.

  Every SOC 2 or ISO 27001 engagement asks the same thing at some point: a sample
  window of the audit trail, in a format a human can read without you writing
  them a script. The honest answer here used to be "we would have to write you a
  script".

  ## What a row contains

  One line per event, in **chain order** rather than timestamp order. The two
  agree in practice, and when they disagree it is because a clock moved — in
  which case the sequence is the one telling the truth about what the database
  actually saw.

  The integrity columns are included deliberately. An export that omits them is a
  list of assertions; an export that carries `sequence`, `previous_hash` and
  `hash` can be checked against the live chain by anyone who receives it, which
  is what makes it evidence rather than a claim. See `AshEnterprise.Audit.Chain`.

  ## Scoping

  Reads run through the ordinary action layer with an actor and a tenant, so an
  export is exactly as wide as its requester's authorization — a tenant
  administrator exports their own organization's trail and nobody else's, by the
  same mechanism that governs every other read. There is no privileged export
  path, which is the point: a second way to read the log would be a second thing
  to get wrong.

  ## Deliberately CSV, not PDF

  Auditors ask for "CSV or PDF", and a PDF of a table is a CSV that has been made
  harder to verify. Nothing here renders one; a spreadsheet does it better and
  the recipient keeps the ability to re-sort and re-check.
  """

  require Ash.Query

  alias AshEnterprise.Audit.EventLog

  # Sobelow reads `@sobelow_skip` out of the source AST, so nothing in the
  # compiled module ever consults it and Elixir reports it as "set but never
  # used" -- which `--warnings-as-errors` turns into a failed build. Persisting
  # it writes the value into the beam's attribute chunk, which counts as a use
  # and is true to what the attribute is: metadata about this module, for another
  # tool to read.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @columns ~w(sequence occurred_at organization_id resource action action_type
              record_id user_id system_actor correlation_id changed_attributes
              previous_hash hash)a

  @doc "The header row, as a list. Public so a test can assert the contract."
  @spec columns() :: [atom()]
  def columns, do: @columns

  @doc """
  Streams the events in `[from, to)` as CSV lines, including the header.

  Options are passed to the read: `:actor` and `:tenant` decide what the export
  can see, and omitting the tenant exports every tenant — which is a deliberate
  choice a caller has to make rather than a default they fall into.
  """
  @spec stream(DateTime.t(), DateTime.t(), keyword()) :: Enumerable.t()
  def stream(from, to, opts \\ []) do
    header = [Enum.map_join(@columns, ",", &to_string/1) <> "\n"]

    rows =
      EventLog
      |> Ash.Query.for_read(:for_export, %{from: from, to: to})
      |> Ash.stream!(Keyword.put_new(opts, :batch_size, 500))
      |> Stream.map(&row/1)

    Stream.concat(header, rows)
  end

  @doc "Writes the export to `path`. Returns the number of events written."
  @spec to_file(Path.t(), DateTime.t(), DateTime.t(), keyword()) :: non_neg_integer()
  # Sobelow flags `File.mkdir_p!` and `File.open!` on a path it cannot prove is
  # constant, which is correct as far as it goes: `to_file/4` writes wherever it
  # is told. The caller is `mix ash_enterprise.audit.export --out`, run by an
  # operator on their own machine against their own filesystem, so the path is
  # the operator's own input in exactly the sense `cp` takes a destination.
  #
  # Skipped locally and by name rather than globally: if a web request ever
  # reaches this function, that is a real finding and this attribute is the thing
  # a reviewer should question.
  @sobelow_skip ["Traversal.FileModule"]
  def to_file(path, from, to, opts \\ []) do
    path |> Path.dirname() |> File.mkdir_p!()

    file = File.open!(path, [:write, :utf8])

    try do
      from
      |> stream(to, opts)
      |> Enum.reduce(-1, fn line, count ->
        IO.write(file, line)
        count + 1
      end)
    after
      File.close(file)
    end
  end

  defp row(event) do
    @columns
    |> Enum.map_join(",", &field(event, &1))
    |> Kernel.<>("\n")
  end

  # `system_actor` and `correlation_id` live in metadata rather than in columns --
  # the first because a system actor is a compile-time constant and cannot be a
  # foreign key, the second because it groups events rather than describing one.
  # Both matter to a reader, so both are lifted into their own column here.
  defp field(event, :system_actor), do: quoted(event.metadata["system_actor"])
  defp field(event, :correlation_id), do: quoted(event.metadata["correlation_id"])

  defp field(event, :changed_attributes) do
    event.changed_attributes |> Map.keys() |> Enum.sort() |> Enum.join(" ") |> quoted()
  end

  defp field(event, column), do: event |> Map.fetch!(column) |> quoted()

  defp quoted(nil), do: ""

  defp quoted(value) do
    string = to_string(value)

    if String.contains?(string, [",", "\"", "\n"]) do
      ~s("#{String.replace(string, "\"", "\"\"")}")
    else
      string
    end
  end
end
