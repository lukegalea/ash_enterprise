defmodule AshEnterprise.Quality.Scorers.SurfaceComposed do
  @moduledoc "`surface`: some tool call composed a surface (`observed.calls`' `surface?`)."

  @behaviour AshEnterprise.Quality.Scorer

  @impl true
  def measure(_assertion, observed) do
    if Enum.any?(Map.get(observed, :calls, []), & &1.surface?),
      do: {:passed, "a surface was composed"},
      else: {:failed, "not: a surface was composed"}
  end
end
