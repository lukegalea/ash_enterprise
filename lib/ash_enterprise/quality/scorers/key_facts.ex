defmodule AshEnterprise.Quality.Scorers.KeyFacts do
  @moduledoc """
  `facts`: the answer carries every key fact, ignoring case. A fact given as a list is
  met by any one of its entries (`%{"facts" => ["Friday", ["two", "separate"]]}`).
  """

  @behaviour AshEnterprise.Quality.Scorer

  @impl true
  def measure(%{expected: %{"facts" => facts}}, %{answer: answer}) do
    text = if is_binary(answer), do: String.downcase(answer), else: ""

    met? = fn
      options when is_list(options) -> Enum.any?(options, &has?(text, &1))
      fact -> has?(text, fact)
    end

    if Enum.all?(facts, met?),
      do: {:passed, "the answer carries every key fact"},
      else: {:failed, "not: the answer carries every key fact"}
  end

  defp has?(text, fact), do: String.contains?(text, String.downcase(fact))
end
