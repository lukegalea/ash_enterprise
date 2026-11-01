defmodule AshEnterprise.Quality.Validations.Cases do
  @moduledoc """
  A suite's cases have unique ids, and every assertion has what it needs to be measured
  (`AshEnterprise.Quality.Assertions.problems/1`).
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Quality.Assertions

  @impl true
  def validate(changeset, _opts, _context) do
    cases = Ash.Changeset.get_attribute(changeset, :cases) || []
    ids = Enum.map(cases, & &1[:id])

    problems =
      (ids -- Enum.uniq(ids))
      |> Enum.uniq()
      |> Enum.map(&"case id #{&1} is used twice")
      |> Kernel.++(
        for c <- cases,
            assertion <- c[:assertions] || [],
            problem <- Assertions.problems(assertion),
            do: "case #{c[:id]}: #{problem}"
      )

    case problems do
      [] -> :ok
      problems -> {:error, field: :cases, message: Enum.join(problems, "; ")}
    end
  end
end
