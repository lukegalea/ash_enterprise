defmodule AshEnterprise.Mdm.MatchReplay do
  @moduledoc """
  Replays a candidate rule set over the pairs stewards already decided, beside
  the rule set it would replace (S1-84). Pure: the bands come from a function
  the caller passes, so the caller decides which band table answers.

  A pair is re-scored from its stored explanation, not from its records: each
  rule's contribution `c` was recorded when the pair was scored, so a new
  weight re-scores it exactly, the way `AshMdm.Match.score/3` folds,
  `sum(w * c) / sum(w)` over every rule. A pair whose explanation does not name
  exactly the rule set's rules was scored by other rules, so it cannot be
  re-scored this way: it is counted as skipped, never replayed with a guess.

  A pair's outcome is its band, `admit`, `review` or `omit`. Against the
  steward's answer, `admit` agrees with a confirm and `omit` with a reject; the
  opposite disagrees, and `review` defers to a person and is neither. Per
  version:

    * `precision`: of the pairs it would admit, the share stewards confirmed;
    * `recall`: of the pairs stewards confirmed, the share it would admit.

  Either is nil when its denominator is zero: no evidence is not a score.

  A pair whose band moves is a change, `toward_admit` or `toward_omit` (with
  `review` between them). A change that lands against the steward, a confirmed
  pair now omitted or a rejected one now admitted, where the replaced rules did
  not, is a flip: the proposal would undo what a person decided.
  """

  @order %{"omit" => 0, "review" => 1, "admit" => 2}

  @typedoc "A pair a steward decided: its candidate id, its explanation and the verdict."
  @type verdict :: %{id: String.t(), explanation: map(), verdict: :match | :non_match}

  @doc "Whether `explanation` names exactly the rules of `rules`."
  @spec comparable?([map()], map()) :: boolean()
  def comparable?(rules, explanation) when is_map(explanation) do
    MapSet.new(rules, & &1["name"]) == MapSet.new(Map.keys(explanation))
  end

  def comparable?(_rules, _explanation), do: false

  @doc "Re-scores a comparable explanation under `rules`' weights."
  @spec score([map()], map()) :: Decimal.t()
  def score(rules, explanation) do
    {total, sum} =
      Enum.reduce(rules, {Decimal.new(0), Decimal.new(0)}, fn rule, {total, sum} ->
        weight = weight(rule)
        contribution = explanation |> Map.fetch!(rule["name"]) |> Map.fetch!("c") |> decimal()
        {Decimal.add(total, weight), Decimal.add(sum, Decimal.mult(weight, contribution))}
      end)

    if Decimal.eq?(total, 0), do: Decimal.new(0), else: Decimal.div(sum, total)
  end

  @doc """
  Replays `verdicts` under `before` and `after`, banding each score with `band`
  (a function from a score to `{:ok, band}` or `{:error, reason}`). Returns
  `{:ok, %{summary: map, changed: [map]}}`, both JSON-safe, or the first
  banding error.
  """
  @spec replay([map()], [map()], [verdict()], (Decimal.t() -> {:ok, atom()} | {:error, term()})) ::
          {:ok, %{summary: map(), changed: [map()]}} | {:error, term()}
  def replay(before, after_rules, verdicts, band) do
    {comparable, skipped} = Enum.split_with(verdicts, &comparable?(before, &1.explanation))

    with {:ok, pairs} <- outcomes(comparable, before, after_rules, band) do
      changed = pairs |> Enum.reject(&(&1["before"] == &1["after"])) |> Enum.map(&change/1)

      {:ok,
       %{
         summary: %{
           "verdicts" => length(verdicts),
           "replayed" => length(pairs),
           "skipped" => length(skipped),
           "changed" => length(changed),
           "toward_admit" => Enum.count(changed, &(&1["direction"] == "toward_admit")),
           "toward_omit" => Enum.count(changed, &(&1["direction"] == "toward_omit")),
           "flips" => Enum.count(changed, & &1["flip"]),
           "before" => stats(pairs, "before"),
           "after" => stats(pairs, "after")
         },
         changed: changed
       }}
    end
  end

  defp outcomes(verdicts, before, after_rules, band) do
    Enum.reduce_while(verdicts, {:ok, []}, fn verdict, {:ok, acc} ->
      score_before = score(before, verdict.explanation)
      score_after = score(after_rules, verdict.explanation)

      with {:ok, band_before} <- band.(score_before),
           {:ok, band_after} <- band.(score_after) do
        pair = %{
          "candidate_id" => verdict.id,
          "verdict" => to_string(verdict.verdict),
          "before" => to_string(band_before),
          "after" => to_string(band_after),
          "score_before" => rounded(score_before),
          "score_after" => rounded(score_after)
        }

        {:cont, {:ok, [pair | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp change(pair) do
    direction =
      if @order[pair["after"]] > @order[pair["before"]], do: "toward_admit", else: "toward_omit"

    flip =
      against?(pair["verdict"], pair["after"]) and not against?(pair["verdict"], pair["before"])

    Map.merge(pair, %{"direction" => direction, "flip" => flip})
  end

  defp against?("match", band), do: band == "omit"
  defp against?("non_match", band), do: band == "admit"

  defp stats(pairs, side) do
    bands = Enum.frequencies_by(pairs, & &1[side])
    confirmed = Enum.count(pairs, &(&1["verdict"] == "match"))
    admitted = Map.get(bands, "admit", 0)
    true_admits = Enum.count(pairs, &(&1["verdict"] == "match" and &1[side] == "admit"))

    %{
      "admit" => admitted,
      "review" => Map.get(bands, "review", 0),
      "omit" => Map.get(bands, "omit", 0),
      "agree" => Enum.count(pairs, &agrees?(&1["verdict"], &1[side])),
      "disagree" => Enum.count(pairs, &against?(&1["verdict"], &1[side])),
      "precision" => ratio(true_admits, admitted),
      "recall" => ratio(true_admits, confirmed)
    }
  end

  defp agrees?("match", band), do: band == "admit"
  defp agrees?("non_match", band), do: band == "omit"

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: rounded(Decimal.div(numerator, denominator))

  defp rounded(decimal), do: decimal |> Decimal.round(4) |> Decimal.to_string(:normal)

  # The weight `AshMdm.Match.score/3` uses: a missing or non-positive weight is 1.
  defp weight(%{"weight" => w}) when is_number(w) and w > 0, do: Decimal.from_float(w / 1)
  defp weight(_rule), do: Decimal.new(1)

  # Decimal in memory, a string once the explanation has been through JSON.
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
end
