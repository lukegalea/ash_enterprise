defmodule AshEnterprise.Quality.Scorers.CitationCoverage do
  @moduledoc """
  `cites`: the answer cites every expected ref as `[[ref]]`. A citation counts only
  when its ref is one the run's tools returned (`observed.refs`): the page links nothing
  else. The result's `measure` is `%{"hit" => n, "of" => expected}`, so a suite's
  coverage is a rate over refs, not only a count of cases.
  """

  @behaviour AshEnterprise.Quality.Scorer

  @cite ~r/\[\[\s*([^\[\]]+?)\s*\]\]/u

  @impl true
  def measure(%{expected: %{"refs" => refs}}, %{answer: answer} = observed) do
    returned = MapSet.new(Map.get(observed, :refs, []))
    text = if is_binary(answer), do: answer, else: ""

    cited =
      @cite
      |> Regex.scan(text)
      |> Enum.flat_map(fn [_, inner] -> split(inner) end)
      |> Enum.filter(&MapSet.member?(returned, &1))

    hit = Enum.count(refs, &(&1 in cited))
    measure = %{"hit" => hit, "of" => length(refs)}

    if hit == length(refs),
      do: {:passed, "every expected ref is cited", measure},
      else: {:failed, "not: every expected ref is cited", measure}
  end

  defp split(inner),
    do: inner |> String.split([",", ";", " "], trim: true) |> Enum.map(&String.trim/1)
end
