defmodule AshEnterprise.Documents.Paper.Actions.ImpactChanges do
  @moduledoc """
  The rows of an impact report surface: for each draft candidate the actor may
  read that carries a report, newest first, every issued document the change
  would affect.

  A clause report gives one row per changed block, with its before and after
  text opened from the run's erasure scope (`[shredded]` once that scope is
  gone), plus one row per document that failed or could not be reproduced. A
  table report gives one row per document that would gain or lose the clause,
  change its reason, or failed. Unchanged documents are counted on the
  candidate (`impact_summary`), not listed.

  Reads the stored report only; nothing is measured here. `read_action` is the
  resource's read that lists candidates, run as the actor.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Documents.Paper.Impact
  alias AshEnterprise.Erasure.Shredded

  require Ash.Query

  @candidates 20

  @impl true
  def run(input, opts, context) do
    input.resource
    |> Ash.Query.for_read(Keyword.fetch!(opts, :read_action), %{},
      actor: context.actor,
      tenant: context.tenant
    )
    |> Ash.Query.filter(status == :draft and not is_nil(impact_report))
    |> Ash.Query.sort(modified_on: :desc)
    |> Ash.Query.limit(@candidates)
    |> Ash.read()
    |> case do
      {:ok, candidates} -> {:ok, Enum.flat_map(candidates, &rows/1)}
      {:error, error} -> {:error, error}
    end
  end

  defp rows(%{impact_report: %{"candidate" => candidate, "cases" => cases}})
       when is_list(cases) do
    name = name(candidate)
    Enum.flat_map(cases, &case_rows(&1, name, candidate["kind"]))
  end

  defp rows(_candidate), do: []

  defp name(%{"kind" => "clause"} = c), do: "#{c["key"]} v#{c["version"]} (#{c["locale"]})"
  defp name(c), do: "#{c["key"]} v#{c["version"]}"

  defp case_rows(%{"outcome" => "unchanged"}, _name, _kind), do: []

  defp case_rows(c, name, "clause") do
    texts = Impact.opened(c)

    common = %{
      candidate: name,
      document: title(texts, c),
      issued: c["issued_at"],
      outcome: Impact.label(c["outcome"]),
      note: note(c, texts)
    }

    case c["blocks"] do
      [_ | _] = blocks ->
        blocks
        |> Enum.with_index()
        |> Enum.map(fn {block, i} ->
          {before, after_text} = text_pair(texts, i)
          Map.merge(common, %{block: block["block"], before: before, after: after_text})
        end)

      _none ->
        [Map.merge(common, %{block: nil, before: nil, after: nil})]
    end
  end

  defp case_rows(c, name, _table) do
    [
      %{
        candidate: name,
        document: c["run_id"],
        issued: c["issued_at"],
        outcome: Impact.label(c["outcome"]),
        block: nil,
        before: include(c["before"]),
        after: include(c["after"]),
        note: c["reason"]
      }
    ]
  end

  defp title(:shredded, _c), do: Shredded.rendered()
  defp title(%{"title" => title}, c) when is_binary(title), do: "#{title} (#{c["run_id"]})"
  defp title(_texts, c), do: c["run_id"]

  defp text_pair(:shredded, _i), do: {Shredded.rendered(), Shredded.rendered()}

  defp text_pair(%{"blocks" => pairs}, i) do
    case Enum.at(pairs, i) do
      [before, after_text] -> {before, after_text}
      _missing -> {nil, nil}
    end
  end

  defp text_pair(_texts, _i), do: {nil, nil}

  defp note(c, texts) do
    reason = if is_map(texts), do: texts["reason"]

    case {c["collateral"], reason} do
      {_collateral, reason} when is_binary(reason) -> reason
      {[_ | _] = collateral, _} -> "also moved: " <> Enum.join(collateral, ", ")
      _plain -> nil
    end
  end

  defp include(%{"include" => true, "rules" => rules}), do: "in (#{Enum.join(rules, ", ")})"
  defp include(%{"include" => false, "rules" => rules}), do: "out (#{Enum.join(rules, ", ")})"
  defp include(_answer), do: "undecided"
end
