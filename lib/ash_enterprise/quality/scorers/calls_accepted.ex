defmodule AshEnterprise.Quality.Scorers.CallsAccepted do
  @moduledoc """
  `calls_accepted`: every tool call the model made was accepted by its tool (argument
  validity). The `measure` is `%{"hit" => accepted, "of" => calls}`: a suite's argument
  validity is a rate over calls.
  """

  @behaviour AshEnterprise.Quality.Scorer

  @impl true
  def measure(_assertion, observed) do
    calls = Map.get(observed, :calls, [])
    accepted = Enum.count(calls, & &1.ok)
    measure = %{"hit" => accepted, "of" => length(calls)}

    if accepted == length(calls),
      do: {:passed, "every call was accepted", measure},
      else: {:failed, "not: every call was accepted", measure}
  end
end
