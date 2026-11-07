defmodule AshEnterprise.Assistant.Lookups.Work do
  @moduledoc """
  `Lookup.WorkEntry`'s `trace` and `explain`: `AshEnterprise.Execution.trace/2` read as
  the person, behind the zone gate, as rows the model reads and cites.

  Nothing the trace could not establish is left out or smoothed over. A source that
  failed, timed out or answered with something other than rows, a source cut short at
  its limit, an entry whose content was never recorded or was erased, and a record the
  person may not read (or that does not exist) each give a `missing` row saying so. The
  model is told to repeat them; an answer that has them never reads as "nothing
  happened".

  ## Refs

  The records a person can open from the answer are the ones a trace can start from:
  agent runs, invocations, process runs and tasks (`citable?/1`). Their `ref` is the
  entry's reference, and the page links it to the explorer rooted there
  (`explorer_path/1`), which reads it again as the reader. Parts of a record (an attempt,
  an effect, a journal step) carry only `entry`.
  """

  use Ash.Resource.ManualRead

  alias AshEnterprise.Assistant.Lookup.WorkEntry
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.LocalTime

  @roots ~w(run invocation process_instance human_task)
  @ref ~r/\A([a-z_]+):([0-9a-fA-F-]{36})\z/

  # The most entries one answer carries: a small model reads every row it is given.
  @shown 60

  @impl true
  def read(query, _data_layer_query, opts, context) do
    Support.gated(query, context, fn read_opts ->
      with {:ok, args} <- args(opts[:op], query.arguments),
           {:ok, %{entries: entries, sources: reports}} <- Execution.trace(args, read_opts) do
        {:ok, rows(opts[:op], args, entries, reports)}
      end
    end)
  end

  @doc "Whether a reference names a record a trace can start from, so a page opens it."
  @spec citable?(String.t()) :: boolean()
  def citable?(ref) when is_binary(ref) do
    case Regex.run(@ref, ref) do
      [_, type, _id] -> type in @roots
      nil -> false
    end
  end

  def citable?(_ref), do: false

  @doc "The explorer, rooted at a citable reference; nil for any other."
  @spec explorer_path(String.t()) :: String.t() | nil
  def explorer_path(ref) do
    if citable?(ref) do
      ref = String.downcase(ref)
      "/app/explorer?" <> URI.encode_query(root: ref, selected: ref)
    end
  end

  # -- the arguments ----------------------------------------------------------------

  defp args(:explain, %{ref: ref}), do: {:ok, %{root_ref: ref}}

  defp args(:trace, arguments) do
    case {blank(arguments[:ref]), blank(arguments[:correlation_id])} do
      {nil, nil} -> {:error, "Give ref or correlation_id."}
      {ref, nil} -> {:ok, %{root_ref: ref}}
      {nil, id} -> {:ok, %{correlation_id: id}}
      {_ref, _id} -> {:error, "Give ref or correlation_id, not both."}
    end
  end

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank(_value), do: nil

  # -- the rows -----------------------------------------------------------------------

  @doc """
  The rows an `op` (`:trace` or `:explain`) answers with, from a trace's `entries` and
  its source `reports`, for the trace arguments `args`. Every gap in them is a `missing`
  row: a source not read, a source cut short, an entry not recorded, more entries than
  one answer carries, and, for `:explain`, a record the trace did not find.
  """
  @spec rows(:trace | :explain, map(), [struct()], [map()]) :: [struct()]
  def rows(:trace, _args, entries, reports), do: shown(Enum.map(entries, &row/1)) ++ cut(reports)

  def rows(:explain, %{root_ref: ref}, entries, reports) do
    {subject, rest} = Enum.split_with(entries, &(&1.source_ref == ref))

    case subject do
      [subject | _] ->
        [%{row(subject) | role: :subject} | shown(Enum.map(rest, &row/1))] ++ cut(reports)

      [] ->
        # What could be read is not about the record asked for: only the gaps are said.
        [not_found(ref) | Enum.filter(Enum.map(rest, &row/1), &(&1.role == :missing))] ++
          cut(reports)
    end
  end

  defp shown(rows) when length(rows) <= @shown, do: rows

  defp shown(rows) do
    Enum.take(rows, @shown) ++
      [
        missing(
          "#{length(rows) - @shown} more entries were read but are not shown here; the " <>
            "explorer shows all of them."
        )
      ]
  end

  defp row(%{source_ref: "source:" <> _name} = gap) do
    %{
      missing("Not read: #{gap.summary}. Records of this kind may exist that are not shown.")
      | at: LocalTime.stamp(gap.at)
    }
  end

  defp row(entry) do
    Support.row(WorkEntry, %{
      role: :entry,
      ref: if(citable?(entry.source_ref), do: entry.source_ref),
      entry: entry.source_ref,
      at: LocalTime.stamp(entry.at),
      kind: entry.kind,
      status: entry.status,
      meaning: meaning(entry.status, entry.blocked_on),
      under: entry.parent_ref,
      definition: entry.definition_ref,
      by: entry.actor_label,
      summary: entry.summary,
      missing:
        if(not entry.recorded?,
          do:
            "Not recorded: what this held was never recorded or has been erased. Its " <>
              "status stands; its content is not known."
        )
    })
  end

  # A source cut short at its limit: the rest of it was not read.
  defp cut(reports) do
    for %{status: :more, source: source} <- reports do
      missing(
        "Cut short: there are more #{source} records than one trace reads, so this is not " <>
          "everything that happened."
      )
    end
  end

  defp not_found(ref) do
    missing(
      "No record #{ref} that you may read: it does not exist, or it is not yours to read. " <>
        "That is not the same as nothing having happened."
    )
  end

  defp missing(text) do
    Support.row(WorkEntry, %{
      role: :missing,
      status: :uncertain,
      meaning: meaning(:uncertain, nil),
      missing: text
    })
  end

  # -- what a status means --------------------------------------------------------------

  defp meaning(:waiting, on), do: "waiting: " <> waiting_on(on)
  defp meaning(:running, :external), do: "running: sent to an outside system, not yet answered"
  defp meaning(:running, _on), do: "running: under way now"
  defp meaning(:succeeded, _on), do: "succeeded: finished as asked"
  defp meaning(:failed, _on), do: "failed: finished without doing what was asked"

  defp meaning(:cancelled, _on),
    do: "cancelled: stopped by a person or a decision not to go ahead"

  defp meaning(_uncertain, _on),
    do: "uncertain: it may or may not have happened; nothing recorded says which"

  defp waiting_on(:approval), do: "for an approval"
  defp waiting_on(:requester), do: "for the requester to answer a question"
  defp waiting_on(:queue), do: "queued to run"
  defp waiting_on(:external), do: "for an outside system to answer"
  defp waiting_on(:human), do: "for a person to act on it"
  defp waiting_on(nil), do: "not started yet"
  defp waiting_on(other), do: "on #{other}"
end
