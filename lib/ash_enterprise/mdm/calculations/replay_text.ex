defmodule AshEnterprise.Mdm.Calculations.ReplayText do
  @moduledoc """
  A match-rule proposal's replay as text for its surface. `part:` picks what:

    * `:summary`: the counts, then each version against the stewards;
    * `:changed_pairs`: one line per pair whose band would move;
    * `:tuning`: one line per rule, its weight before and after.

  Reads only the proposal's own stored replay. A precision or recall with no
  denominator reads "none", never zero.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    if opts[:part] in [:summary, :changed_pairs, :tuning],
      do: {:ok, opts},
      else: {:error, "part must be :summary, :changed_pairs or :tuning"}
  end

  @impl true
  def load(_query, opts, _context) do
    case opts[:part] do
      :summary -> [:replay]
      :changed_pairs -> [:changed_pairs]
      :tuning -> [:tuning]
    end
  end

  @impl true
  def calculate(records, opts, _context) do
    {:ok, Enum.map(records, &text(opts[:part], &1))}
  end

  defp text(:summary, %{replay: %{} = replay}) do
    Enum.join(
      [
        "#{replay["replayed"]} of #{replay["verdicts"]} steward verdicts replayed " <>
          "(#{replay["skipped"]} scored by other rules)",
        "#{replay["changed"]} would change band: #{replay["toward_admit"]} toward admit, " <>
          "#{replay["toward_omit"]} toward omit",
        "#{replay["flips"]} would undo a steward's decision",
        version("Active rules", replay["before"]),
        version("Proposed rules", replay["after"])
      ],
      "\n"
    )
  end

  defp text(:changed_pairs, %{changed_pairs: []}), do: "No pair would change band."

  defp text(:changed_pairs, %{changed_pairs: pairs}) do
    Enum.map_join(pairs, "\n", fn pair ->
      flip = if pair["flip"], do: " (against the steward)", else: ""

      "#{pair["candidate_id"]}: #{pair["verdict"]}, #{pair["before"]} → #{pair["after"]} " <>
        "(#{pair["score_before"]} → #{pair["score_after"]})#{flip}"
    end)
  end

  defp text(:tuning, %{tuning: entries}) do
    Enum.map_join(entries, "\n", fn entry ->
      "#{entry["rule"]}: #{entry["weight_before"]} → #{entry["weight_after"]} (#{entry["status"]})"
    end)
  end

  defp text(_part, _record), do: nil

  defp version(label, stats) do
    "#{label}: #{stats["admit"]} admit, #{stats["review"]} review, #{stats["omit"]} omit; " <>
      "agrees with #{stats["agree"]}, disagrees with #{stats["disagree"]}; " <>
      "precision #{stats["precision"] || "none"}, recall #{stats["recall"] || "none"}"
  end
end
