defmodule AshEnterprise.Quality.Scorers.ProposalMade do
  @moduledoc """
  `proposal`: a call proposed a change of the kind `expected["kind"]` names, or, for
  `%{"kind" => false}`, no call proposed anything.
  """

  @behaviour AshEnterprise.Quality.Scorer

  @impl true
  def measure(%{expected: %{"kind" => kind}}, observed) do
    kinds =
      observed |> Map.get(:calls, []) |> Enum.map(& &1.proposal) |> Enum.reject(&is_nil/1)

    cond do
      kind == false and kinds == [] -> {:passed, "no change was proposed"}
      kind == false -> {:failed, "not: no change was proposed"}
      kind in kinds -> {:passed, "a change of the kind was proposed"}
      true -> {:failed, "not: a change of the kind was proposed"}
    end
  end
end
