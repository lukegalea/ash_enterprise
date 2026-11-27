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

  ## Documented by a journey

  A second, separate account (`documentation_problems/3`): every surface and
  action is either walked by one of the host's journeys (`ash_journeys`,
  `AshBrowserTests.Journeys.proven/3`) or carries an `:undocumented` waiver
  with a reason: `{:undocumented, :surface, id, reason}` or
  `{:undocumented, :action, {surface_id, action_id}, reason}`. It lives in the
  same waiver list as the exercise waivers, and each account reads only its own
  kind. A journey names a surface by its registry id (`:people` is `"people"`)
  and a row action by its manifest id, as the generator does (`"row:<id>"`).

  An `:undocumented` waiver goes stale like any other: when it names nothing
  declared, or something a journey now walks.

  Only a journey whose approved run still proves it counts as walking anything:
  `AshBrowserTests.Journeys.proven/3` reads the walks from the journeys the lock
  holds current in every locale they declare, and
  `AshBrowserTests.Journeys.assert_documented!/3` runs this account on them.

  ## Waivers are written by hand

  A waiver is a decision someone made about one thing, so the documentation
  account (through `waiver_problems/1`) fails two waivers of the same thing, and
  two waivers that give one reason
  (compared without case, spacing, or the ids they name). A list mapped from a
  registry with a stock reason is refused that way.

  ## Coverage

  `documentation_coverage/2` counts what journeys walk against a set of surfaces,
  such as a host's whole registry. Waivers never count: the number is how much is
  documented, not how much is accounted for.
  """

  alias AshBrowserTests.Action
  alias AshBrowserTests.Surface

  @type waiver ::
          {:surface, String.t(), String.t()}
          | {:action, String.t(), String.t(), String.t()}
          | {:undocumented, :surface, String.t(), String.t()}
          | {:undocumented, :action, {String.t(), String.t()}, String.t()}
  @type documented ::
          {:journey, String.t(), {:surface, String.t()} | {:action, String.t(), String.t()}}
  @type problem :: {atom(), term()}
  @type coverage :: %{
          surfaces: %{documented: non_neg_integer(), of: non_neg_integer()},
          actions: %{documented: non_neg_integer(), of: non_neg_integer()}
        }

  @doc """
  The problems in a set of surfaces, generated test ids and waivers. `exercised` is
  the list of `{:surface, id}` and `{:action, surface_id, action_id}` that have a
  generated test.
  """
  @spec problems([Surface.t()], [waiver()], list()) :: [problem()]
  def problems(surfaces, waivers, exercised) do
    waivers = Enum.reject(waivers, &undocumented?/1)
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

  @doc """
  The problems in the documentation account (see the moduledoc): `documented` is
  what the host's journeys walk, as `{:journey, journey_id, {:surface, id}}` and
  `{:journey, journey_id, {:action, surface_id, action_id}}`, from
  `AshBrowserTests.Journeys.proven/3`. Exercise waivers in `waivers` are ignored;
  the `:undocumented` ones are also checked together (`waiver_problems/1`).
  """
  @spec documentation_problems([Surface.t()], [waiver()], [documented()]) :: [problem()]
  def documentation_problems(surfaces, waivers, documented) do
    waivers = Enum.filter(waivers, &undocumented?/1)
    walked = Map.new(documented, fn {:journey, journey, key} -> {key, journey} end)
    known = MapSet.new(obligations(surfaces))

    undocumented =
      Enum.flat_map(surfaces, fn %Surface{} = surface ->
        if waived?(waivers, {:undocumented, :surface, surface.id}) do
          []
        else
          surface_key = {:surface, surface.id}

          surface_problem =
            if Map.has_key?(walked, surface_key),
              do: [],
              else: [{:undocumented_surface, surface.id}]

          action_problems =
            for %Action{id: id} <- surface.actions,
                not Map.has_key?(walked, {:action, surface.id, id}),
                not waived?(waivers, {:undocumented, :action, {surface.id, id}}),
                do: {:undocumented_action, {surface.id, id}}

          surface_problem ++ action_problems
        end
      end)

    refused =
      Enum.flat_map(waivers, fn {:undocumented, kind, id, reason} = waiver ->
        key = if kind == :surface, do: {:surface, id}, else: Tuple.insert_at(id, 0, :action)

        cond do
          not reason_ok?(reason) -> [{:waiver_without_reason, waiver}]
          not MapSet.member?(known, key) -> [{:stale_waiver, waiver}]
          journey = walked[key] -> [{:documented_waiver, {waiver, journey}}]
          true -> []
        end
      end)

    undocumented ++ refused ++ waiver_problems(waivers)
  end

  @doc "Raises `ExUnit.AssertionError` if `documentation_problems/3` finds anything."
  @spec assert_documented!([Surface.t()], [waiver()], [documented()]) :: :ok
  def assert_documented!(surfaces, waivers, documented) do
    case documentation_problems(surfaces, waivers, documented) do
      [] ->
        :ok

      problems ->
        raise ExUnit.AssertionError,
          message:
            "the documentation ledger is not complete:\n" <>
              Enum.map_join(problems, "\n", &format/1)
    end
  end

  @doc """
  The problems in a list of waivers taken together: two waivers of the same
  thing (`{:duplicate_waiver, waiver}`, the second), and waivers that give one
  reason between them (`{:repeated_reason, waivers}`). Reasons are compared
  without case, punctuation, spacing, or the ids of what each waiver names, so a
  stock reason with the id spliced in is still one reason. A blank reason is
  left to `problems/3` and `documentation_problems/3`.
  """
  @spec waiver_problems([waiver()]) :: [problem()]
  def waiver_problems(waivers) do
    {duplicates, _seen} =
      Enum.flat_map_reduce(waivers, MapSet.new(), fn waiver, seen ->
        key = Tuple.delete_at(waiver, tuple_size(waiver) - 1)

        if MapSet.member?(seen, key),
          do: {[{:duplicate_waiver, waiver}], seen},
          else: {[], MapSet.put(seen, key)}
      end)

    repeated =
      waivers
      |> Enum.filter(&reason_ok?(reason(&1)))
      |> Enum.group_by(&stock_reason/1)
      |> Enum.filter(fn {_reason, group} -> length(group) > 1 end)
      |> Enum.sort_by(fn {_reason, [first | _]} -> Enum.find_index(waivers, &(&1 == first)) end)
      |> Enum.map(fn {_reason, group} -> {:repeated_reason, group} end)

    duplicates ++ repeated
  end

  @doc """
  How much of `surfaces` the journeys walk: surfaces, and actions, that some
  `documented` entry names, out of all of them. Waivers are not an input.
  """
  @spec documentation_coverage([Surface.t()], [documented()]) :: coverage()
  def documentation_coverage(surfaces, documented) do
    walked = MapSet.new(documented, fn {:journey, _journey, key} -> key end)

    actions =
      for %Surface{} = surface <- surfaces, action <- surface.actions, do: {surface, action}

    %{
      surfaces: %{
        documented: Enum.count(surfaces, &MapSet.member?(walked, {:surface, &1.id})),
        of: length(surfaces)
      },
      actions: %{
        documented:
          Enum.count(actions, fn {surface, action} ->
            MapSet.member?(walked, {:action, surface.id, action.id})
          end),
        of: length(actions)
      }
    }
  end

  @doc "One problem as a line of a ledger's failure message."
  @spec format_problem(problem()) :: String.t()
  def format_problem(problem), do: format(problem)

  defp undocumented?(waiver), do: elem(waiver, 0) == :undocumented

  # The reason with what makes it particular to its waiver taken out: case,
  # punctuation, spacing, and the ids the waiver names.
  defp stock_reason(waiver) do
    words = fn text ->
      text |> String.downcase() |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    end

    ids = waiver |> ids() |> Enum.flat_map(words) |> MapSet.new()
    waiver |> reason() |> words.() |> Enum.reject(&MapSet.member?(ids, &1))
  end

  defp ids({:surface, id, _reason}), do: [id]
  defp ids({:action, surface_id, action_id, _reason}), do: [surface_id, action_id]
  defp ids({:undocumented, :surface, id, _reason}), do: [id]

  defp ids({:undocumented, :action, {surface_id, action_id}, _reason}),
    do: [surface_id, action_id]

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

  defp waived?(waivers, {:undocumented, kind, id}) do
    Enum.any?(waivers, &match?({:undocumented, ^kind, ^id, _reason}, &1))
  end

  defp malformed_waivers(waivers) do
    Enum.flat_map(waivers, fn waiver ->
      if reason_ok?(reason(waiver)), do: [], else: [{:waiver_without_reason, waiver}]
    end)
  end

  defp reason({:surface, _id, reason}), do: reason
  defp reason({:action, _surface_id, _action_id, reason}), do: reason
  defp reason({:undocumented, _kind, _id, reason}), do: reason

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

  defp format({:undocumented_surface, id}) do
    "  surface #{inspect(id)} is in no journey and has no :undocumented waiver"
  end

  defp format({:undocumented_action, {surface_id, action_id}}) do
    "  action #{inspect(action_id)} on surface #{inspect(surface_id)} is in no journey " <>
      "and has no :undocumented waiver"
  end

  defp format({:documented_waiver, {waiver, journey}}) do
    "  waiver #{inspect(waiver)} excuses what journey #{journey} walks; remove it"
  end

  defp format({:duplicate_waiver, waiver}) do
    "  waiver #{inspect(waiver)} waives what an earlier waiver already does; keep one"
  end

  defp format({:repeated_reason, waivers}) do
    "  #{length(waivers)} waivers give one reason between them, so none is a decision " <>
      "about its own surface or action; write each its own reason:\n" <>
      Enum.map_join(waivers, "\n", &"    #{inspect(&1)}")
  end

  defp format({:stale_waiver, waiver}) do
    "  waiver #{inspect(waiver)} names nothing declared; remove it"
  end
end
