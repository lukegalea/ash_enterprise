defmodule AshEnterprise.Quality.Validations.Cases do
  @moduledoc """
  A suite's cases have unique ids, every assertion has what it needs to be measured
  (`AshEnterprise.Quality.Assertions.problems/1`), and every injection case can be scored
  (`AshEnterprise.Quality.Injection.problems/1`).
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Quality.{Assertions, Injection}

  @impl true
  def validate(changeset, _opts, _context) do
    case problems(Ash.Changeset.get_attribute(changeset, :cases) || []) do
      [] -> :ok
      problems -> {:error, field: :cases, message: Enum.join(problems, "; ")}
    end
  end

  @doc "What is wrong with `cases`, as messages; `[]` when nothing is."
  @spec problems([map()]) :: [String.t()]
  def problems(cases) do
    ids = Enum.map(cases, & &1[:id])

    (ids -- Enum.uniq(ids))
    |> Enum.uniq()
    |> Enum.map(&"case id #{&1} is used twice")
    |> Kernel.++(
      for c <- cases,
          assertion <- c[:assertions] || [],
          problem <- Assertions.problems(assertion),
          do: "case #{c[:id]}: #{problem}"
    )
    |> Kernel.++(Injection.problems(cases))
  end
end
