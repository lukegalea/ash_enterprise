defmodule AshEnterprise.Planning.Lowering do
  @moduledoc """
  The ONE place the host lowers read rows into a model's solver data, and lifts the solver's
  answer back into typed assignments (ADR 0062). Pure: no I/O, no Ash, no clock.

  > **Wave-3 boundary.** This module is *host* lowering for the `personal_week` slot model.
  > The extracted `ash_planning` package must NOT absorb it: the package ships the
  > `Backend`/`Validator` behaviours and generic validators; what a given model's data looks
  > like, and which rows feed it, is the host's declaration.

  ## The slot domain (`personal_week`)

  Time is integer 15-minute slots counted from `week_start` (a UTC instant; the week is seven
  days of 96 slots). Every conversion rounds the *conservative* way, so the solver can only
  ever be stricter than the person's calendar:

    * work window: start rounds up, end rounds down; a day whose window is empty has
      `work_start == work_end == 0` (nothing is scheduled on it);
    * busy intervals (pinned work, meetings): start rounds down, end rounds up, clamped to
      the horizon;
    * task durations round up; a due instant rounds down (finish by the slot before);
    * `t_release` is the cutoff slot: nothing is placed before the run's knowledge cutoff.

  All values in the payload are integers or booleans: no decimals, no floats, no strings but
  the ids. Calendar zone is UTC (the requester's zone is a later binding concern).

  ## Payload shape

  `lower/1` returns a string-keyed map: the model's data parameters (exactly what
  `personal_week.mzn` declares), plus

    * `"ids"` — `%{"tasks" => [...], "meetings" => [...], "pinned" => [...]}`, index-aligned
      with the model's arrays. The independent validator resolves assignment ids through it.

  `SnapshotBuilder` adds `"snapshot"` (the references-and-hashes envelope). Neither key is a
  model parameter: `solver_data/1` drops both, and is what the backend must be handed.

  ## Assignments

  `assignments/2` lifts the solver's output arrays (`scheduled`, `start`, `attended`) into
  `[%{"kind" => "task", "id" => id, "scheduled" => bool, "start_slot" => int} |
  %{"kind" => "meeting", "id" => id, "attended" => bool}]`, the shape both the validator and
  the apply flow read. `slot_to_datetime/2` is the one inverse of the slot arithmetic.
  """

  @slot_seconds 900
  @day_slots 96
  @horizon_days 7
  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @doc "Slot length in minutes."
  @spec slot_minutes() :: pos_integer()
  def slot_minutes, do: div(@slot_seconds, 60)

  @doc "Slots in the planning horizon."
  @spec horizon_slots() :: pos_integer()
  def horizon_slots, do: @day_slots * @horizon_days

  @doc "Lowercase English weekday names, Monday first (the DMN's input vocabulary)."
  @spec weekdays() :: [String.t()]
  def weekdays, do: @weekdays

  @typedoc "What the builder hands over; everything already read and typed."
  @type input :: %{
          required(:week_start) => DateTime.t(),
          required(:cutoff) => DateTime.t(),
          required(:tasks) => [
            %{id: String.t(), duration_minutes: pos_integer(), due_at: DateTime.t() | nil}
          ],
          required(:meetings) => [
            %{
              id: String.t(),
              starts_at: DateTime.t(),
              ends_at: DateTime.t(),
              mandatory?: boolean(),
              priority: pos_integer()
            }
          ],
          required(:pins) => [%{id: String.t(), starts_at: DateTime.t(), ends_at: DateTime.t()}],
          required(:requirements) => %{String.t() => map()}
        }

  @doc """
  Lowers `input` to the payload map. `{:error, {:requirements, weekday}}` when a weekday's
  requirements are missing or malformed: a refusal, never a silent default.
  """
  @spec lower(input()) :: {:ok, map()} | {:error, term()}
  def lower(%{week_start: ws, cutoff: cutoff} = input) do
    horizon = horizon_slots()

    with {:ok, days} <- days(input.requirements) do
      tasks = Enum.sort_by(input.tasks, & &1.id)
      meetings = Enum.sort_by(input.meetings, &{&1.starts_at, &1.id})
      pins = input.pins |> Enum.sort_by(&{&1.starts_at, &1.id}) |> busy(ws, horizon)
      meeting_busy = busy(meetings, ws, horizon)
      release = clamp(ceil_slot(cutoff, ws), 0, horizon)

      {:ok,
       %{
         "slot_minutes" => slot_minutes(),
         "day_slots" => @day_slots,
         "day_work_start" => Enum.map(days, & &1.work_start),
         "day_work_end" => Enum.map(days, & &1.work_end),
         "day_buffer" => Enum.map(days, & &1.buffer),
         "break_after_slots" => hd(days).break_after,
         "break_slots" => hd(days).break,
         "n_pinned" => length(pins),
         "pin_start" => Enum.map(pins, & &1.from),
         "pin_end" => Enum.map(pins, & &1.to),
         "n_meetings" => length(meeting_busy),
         "m_start" => Enum.map(meeting_busy, & &1.from),
         "m_end" => Enum.map(meeting_busy, & &1.to),
         "m_mandatory" => Enum.map(meeting_busy, & &1.source.mandatory?),
         "m_priority" => Enum.map(meeting_busy, & &1.source.priority),
         "n_tasks" => length(tasks),
         "t_dur" => Enum.map(tasks, &ceil_div(&1.duration_minutes * 60, @slot_seconds)),
         "t_release" => Enum.map(tasks, fn _ -> release end),
         "t_due" => Enum.map(tasks, &due_slot(&1.due_at, ws, horizon)),
         # v1 dogfood semantics: every plannable open task is part of the week —
         # parking tasks is not a plan. Optional/must distinctions arrive with the
         # Wave-4+ task model.
         "t_must" => Enum.map(tasks, fn _ -> true end),
         "t_hard_due" => Enum.map(tasks, fn _ -> false end),
         "t_weight" => Enum.map(tasks, fn _ -> 1 end),
         "n_prec" => 0,
         "prec_before" => [],
         "prec_after" => [],
         "ids" => %{
           "tasks" => Enum.map(tasks, & &1.id),
           "meetings" => Enum.map(meeting_busy, & &1.source.id),
           "pinned" => Enum.map(pins, & &1.source.id)
         }
       }}
    end
  end

  @doc "The map the solver is given: the payload minus the keys that are not model parameters."
  @spec solver_data(map()) :: map()
  def solver_data(payload) when is_map(payload),
    do:
      payload
      |> Map.drop(["ids", "snapshot"])
      |> Map.reject(fn {_k, v} -> is_list(v) and v == [] end)

  # Empty lists are dropped: MiniZincData.to_dzn/1 emits them as `array0d([])`,
  # which MiniZinc 2.10 rejects, and their size is already pinned by the
  # matching `n_*` scalar.

  @doc """
  The model's output arrays lifted into assignments, index-aligned with `payload["ids"]`.
  `{:error, :shape}` when the arrays do not match the payload.
  """
  @spec assignments(map(), map()) :: {:ok, [map()]} | {:error, :shape}
  def assignments(%{"ids" => %{"tasks" => task_ids, "meetings" => meeting_ids}}, data)
      when is_map(data) do
    with scheduled when is_list(scheduled) <- data["scheduled"],
         start when is_list(start) <- data["start"],
         attended when is_list(attended) <- data["attended"],
         true <- length(scheduled) == length(task_ids) and length(start) == length(task_ids),
         true <- length(attended) == length(meeting_ids) do
      tasks =
        [task_ids, scheduled, start]
        |> Enum.zip()
        |> Enum.map(fn {id, scheduled?, slot} ->
          %{
            "kind" => "task",
            "id" => id,
            "scheduled" => scheduled? == true,
            "start_slot" => to_int(slot)
          }
        end)

      meetings =
        meeting_ids
        |> Enum.zip(attended)
        |> Enum.map(fn {id, attended?} ->
          %{"kind" => "meeting", "id" => id, "attended" => attended? == true}
        end)

      {:ok, tasks ++ meetings}
    else
      _ -> {:error, :shape}
    end
  end

  def assignments(_payload, _data), do: {:error, :shape}

  @doc "The instant of `slot` counted from `week_start`."
  @spec slot_to_datetime(DateTime.t(), integer()) :: DateTime.t()
  def slot_to_datetime(%DateTime{} = week_start, slot) when is_integer(slot),
    do: DateTime.add(week_start, slot * @slot_seconds, :second)

  @doc "The Monday 00:00 UTC of the ISO week containing `instant`."
  @spec week_start(DateTime.t()) :: DateTime.t()
  def week_start(%DateTime{} = instant) do
    date = instant |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    monday = Date.add(date, 1 - Date.day_of_week(date))
    DateTime.new!(monday, ~T[00:00:00.000000], "Etc/UTC")
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp days(requirements) do
    @weekdays
    |> Enum.reduce_while([], fn weekday, acc ->
      case day(Map.get(requirements, weekday)) do
        {:ok, day} -> {:cont, [day | acc]}
        :error -> {:halt, {:error, {:requirements, weekday}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      days -> {:ok, Enum.reverse(days)}
    end
  end

  defp day(%{} = req) do
    with {:ok, start} <- minutes(req, "workStartMinute"),
         {:ok, finish} <- minutes(req, "workEndMinute"),
         {:ok, buffer} <- minutes(req, "bufferMinutes"),
         {:ok, break_after} <- minutes(req, "breakAfterMinutes"),
         {:ok, break} <- minutes(req, "breakMinutes") do
      work_start = ceil_div(start * 60, @slot_seconds)
      work_end = div(finish * 60, @slot_seconds)
      {work_start, work_end} = if work_end > work_start, do: {work_start, work_end}, else: {0, 0}

      {:ok,
       %{
         work_start: work_start,
         work_end: work_end,
         buffer: ceil_div(buffer * 60, @slot_seconds),
         break_after: ceil_div(break_after * 60, @slot_seconds),
         break: ceil_div(break * 60, @slot_seconds)
       }}
    end
  end

  defp day(_missing), do: :error

  defp minutes(req, key) do
    case Map.get(req, key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  # Busy intervals in slots, clamped; empty ones dropped.
  defp busy(items, ws, horizon) do
    items
    |> Enum.map(fn item ->
      %{
        source: item,
        from: clamp(floor_slot(item.starts_at, ws), 0, horizon),
        to: clamp(ceil_slot(item.ends_at, ws), 0, horizon)
      }
    end)
    |> Enum.filter(&(&1.to > &1.from))
  end

  defp due_slot(nil, _ws, horizon), do: horizon
  defp due_slot(%DateTime{} = due, ws, horizon), do: clamp(floor_slot(due, ws), 0, horizon)

  defp floor_slot(instant, ws),
    do: Integer.floor_div(DateTime.diff(instant, ws, :microsecond), @slot_seconds * 1_000_000)

  defp ceil_slot(instant, ws),
    do: -Integer.floor_div(-DateTime.diff(instant, ws, :microsecond), @slot_seconds * 1_000_000)

  defp ceil_div(a, b), do: -Integer.floor_div(-a, b)
  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp to_int(n) when is_integer(n), do: n
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(_other), do: 0
end
