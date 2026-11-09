defmodule AshBrowserTests.Ledger do
  @moduledoc """
  The accounting behind the generated suite: every surface and action is either
  exercised by a generated test or carries a written reason in the host's waiver
  list. Anything else fails, so a new surface or action cannot go uncovered without
  someone writing down why.

  It also fails a waiver that has no reason, or that names something no longer
  declared, because a stale waiver hides the gap it once excused.

  A waiver is `{:surface, id, reason}` or `{:action, surface_id, action_id, reason}`.
  A waived surface covers its actions: nothing can be driven on a page that is not
  opened.
  """

  alias AshBrowserTests.Action
  alias AshBrowserTests.Surface

  @type waiver ::
          {:surface, String.t(), String.t()}
          | {:action, String.t(), String.t(), String.t()}
  @type problem :: {atom(), term()}

  @doc """
  The problems in a set of surfaces, generated test ids and waivers. `exercised` is
  the list of `{:surface, id}` and `{:action, surface_id, action_id}` that have a
  generated test.
  """
  @spec problems([Surface.t()], [waiver()], list()) :: [problem()]
  def problems(surfaces, waivers, exercised) do
    exercised = MapSet.new(exercised)
    obligations = obligations(surfaces)

    uncovered_problems(surfaces, waivers, exercised) ++
      malformed_waivers(waivers) ++
      unknown_waivers(waivers, obligations)
  end

  @doc "Raises `ExUnit.AssertionError` if `problems/3` finds anything."
  @spec assert_complete!([Surface.t()], [waiver()], list()) :: :ok
  def assert_complete!(surfaces, waivers, exercised) do
    case problems(surfaces, waivers, exercised) do
      [] ->
        :ok

      problems ->
        raise ExUnit.AssertionError,
          message:
            "the surface ledger is not complete:\n" <>
              Enum.map_join(problems, "\n", &format/1)
    end
  end

  defp obligations(surfaces) do
    Enum.flat_map(surfaces, fn %Surface{} = surface ->
      [{:surface, surface.id} | Enum.map(surface.actions, &{:action, surface.id, &1.id})]
    end)
  end

  defp uncovered_problems(surfaces, waivers, exercised) do
    Enum.flat_map(surfaces, fn surface ->
      surface_waived? = waived?(waivers, {:surface, surface.id})

      surface_problem(surface, surface_waived?, exercised) ++
        action_problems(surface, surface_waived?, waivers, exercised)
    end)
  end

  defp surface_problem(surface, surface_waived?, exercised) do
    if surface_waived? or MapSet.member?(exercised, {:surface, surface.id}) do
      []
    else
      [{:unexercised_surface, surface.id}]
    end
  end

  # Waiving the surface covers its actions.
  defp action_problems(%Surface{}, true, _waivers, _exercised), do: []

  defp action_problems(%Surface{} = surface, false, waivers, exercised) do
    Enum.flat_map(surface.actions, fn %Action{} = action ->
      key = {:action, surface.id, action.id}

      if waived?(waivers, key) or MapSet.member?(exercised, key) do
        []
      else
        [{:unexercised_action, {surface.id, action.id}}]
      end
    end)
  end

  defp waived?(waivers, {:surface, id}) do
    Enum.any?(waivers, &match?({:surface, ^id, _reason}, &1))
  end

  defp waived?(waivers, {:action, surface_id, action_id}) do
    Enum.any?(waivers, &match?({:action, ^surface_id, ^action_id, _reason}, &1))
  end

  defp malformed_waivers(waivers) do
    Enum.flat_map(waivers, fn waiver ->
      if reason_ok?(reason(waiver)), do: [], else: [{:waiver_without_reason, waiver}]
    end)
  end

  defp reason({:surface, _id, reason}), do: reason
  defp reason({:action, _surface_id, _action_id, reason}), do: reason

  defp reason_ok?(reason), do: is_binary(reason) and String.trim(reason) != ""

  defp unknown_waivers(waivers, obligations) do
    known = MapSet.new(obligations)

    Enum.flat_map(waivers, fn waiver ->
      key =
        case waiver do
          {:surface, id, _reason} -> {:surface, id}
          {:action, surface_id, action_id, _reason} -> {:action, surface_id, action_id}
        end

      if MapSet.member?(known, key), do: [], else: [{:stale_waiver, waiver}]
    end)
  end

  defp format({:unexercised_surface, id}) do
    "  surface #{inspect(id)} has no test and no waiver"
  end

  defp format({:unexercised_action, {surface_id, action_id}}) do
    "  action #{inspect(action_id)} on surface #{inspect(surface_id)} has no test and no waiver"
  end

  defp format({:waiver_without_reason, waiver}) do
    "  waiver #{inspect(waiver)} has no reason"
  end

  defp format({:stale_waiver, waiver}) do
    "  waiver #{inspect(waiver)} names nothing declared; remove it"
  end
end
