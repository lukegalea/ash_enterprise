defmodule AshEnterprise.Artifacts.Differs.Suite do
  @moduledoc """
  Two versions of an evaluation suite (`AshEnterprise.Quality.Suite`), by what it
  measures:

    * **cases**: each case by its stable id, added or removed, and for one in both its
      input, target, fixtures, split, tags and assertions;
    * **thresholds** and the **primary metric** the release gate reads;
    * **scorers**: the judged scorers reported beside the assertions, by name.

  Provenance (where the cases came from) is shown on the header, not diffed: it changes
  nothing a run is scored on.
  """

  @behaviour AshEnterprise.Artifacts.Differ

  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Artifacts.Change

  @impl true
  def aspects do
    [
      cases: dgettext_noop("artifacts", "Cases"),
      thresholds: dgettext_noop("artifacts", "Thresholds"),
      primary_metric: dgettext_noop("artifacts", "Primary metric"),
      scorers: dgettext_noop("artifacts", "Scorers")
    ]
  end

  @impl true
  def diff(old, new, _opts) do
    {:ok,
     Change.keyed(:cases, cases(old.cases), cases(new.cases)) ++
       Change.keyed(:thresholds, old.thresholds || %{}, new.thresholds || %{}) ++
       Change.value(:primary_metric, old.primary_metric, new.primary_metric) ++
       Change.keyed(:scorers, scorers(old.scorers), scorers(new.scorers))}
  end

  defp cases(cases) do
    Map.new(cases || [], fn c ->
      c = Map.new(c, fn {field, value} -> {to_string(field), value} end)
      {c["id"], Map.delete(c, "id")}
    end)
  end

  defp scorers(scorers) do
    scorers
    |> List.wrap()
    |> Enum.with_index()
    |> Map.new(fn {scorer, index} ->
      {to_string(scorer["name"] || scorer[:name] || "##{index + 1}"), scorer}
    end)
  end
end
