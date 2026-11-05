defmodule AshEnterprise.Planning.Changes.ApplyCandidate do
  @moduledoc """
  The host side of `Candidate.apply` (ADR 0062, ADR 0059): a person commits an approved,
  checked candidate by writing through existing Ash actions, after a freshness recheck.

      # in AshEnterprise.Planning.Candidate
      changes do
        change AshEnterprise.Planning.Changes.ApplyCandidate, on: [:update], where: action_is(:apply)
      end

  `apply` is human-only (neither engine bypass nor the machinery actor reaches it), so the
  actor on the changeset is the approving person, and every write below is made as them.

  ## Order of events

  The fragment's `apply` validations (approved, correct, current) have already passed. Inside
  the action's transaction, before the disposition is written:

    1. **Recheck every source.** The run's sealed problem carries the snapshot envelope; each
       input with a source `(resource, id, version_number)` is read again. A row that is gone
       or whose `version_number` moved is *drift*. Any drift refuses the apply and, after the
       transaction, `mark_stale` records the candidate `:stale` (machinery actor): a stale
       candidate is never applied, it is superseded by a replan.
    2. **Write, in one transaction.** Each scheduled task assignment becomes
       `Canonical.Task.schedule_mine/4`, each assignment that leaves a currently scheduled task
       unscheduled `unschedule_mine/2`, all as the approving person inside one
       `Ash.transaction/2`. Meeting assignments write nothing: a meeting is a fact the plan
       respected, not something it changes. The first refusal (a validation, an optimistic-lock
       conflict from a concurrent edit) rolls every write back.
    3. A refusal after the recheck passed also records the candidate `:rejected` (as the
       person, through `reject`), after the rollback. The error is returned either way.

  ## Targets without a version precondition (contingency C6)

  Only a target whose snapshot source carries a `version_number` is written automatically.
  Such an assignment is excluded, counted in the context key `:planning_excluded`, and left
  for the person to do by hand.

  A snapshot is read through `AshEnterprise.Planning.SnapshotBuilder`, which verifies its
  digest; a payload that is shredded, unreadable or unverifiable refuses the apply.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.{CalendarEvent, Task}
  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.{Lowering, Run, SnapshotBuilder}
  alias AshEnterprise.Platform.SystemActor

  @sources %{
    "AshEnterprise.Canonical.Task" => Task,
    "AshEnterprise.Canonical.CalendarEvent" => CalendarEvent
  }

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&write(&1, context))
    |> Ash.Changeset.after_transaction(&settle(&1, &2, context))
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:not_atomic, "apply writes other resources"}

  # ── inside the transaction ─────────────────────────────────────────────────

  defp write(changeset, context) do
    candidate = changeset.data
    tenant = changeset.tenant
    actor = context.actor

    with {:ok, run} <- Ash.get(Run, candidate.run_id, tenant: tenant, authorize?: false),
         {:ok, payload} <- SnapshotBuilder.problem_payload(run),
         {:ok, snapshot} <- SnapshotBuilder.snapshot_from_payload(payload),
         {:ok, rows} <- recheck(snapshot, tenant),
         {:ok, assignments} <- assignments(candidate, tenant) do
      transact(changeset, snapshot, payload, rows, assignments, actor, tenant)
    else
      {:drift, source} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :drift})
        |> Ash.Changeset.add_error(
          field: :freshness,
          message: "a source changed since the snapshot (#{source}); the candidate is stale"
        )

      {:error, reason} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :unreadable})
        |> Ash.Changeset.add_error(
          field: :assignments,
          message: "cannot apply: #{reason_text(reason)}"
        )
    end
  end

  # Every source row is read again; `{:drift, "<resource> <id>"}` on the first that moved.
  defp recheck(snapshot, tenant) do
    snapshot.inputs
    |> Enum.filter(&(&1.status == :value and not is_nil(&1.source)))
    |> Enum.reduce_while({:ok, %{}}, fn %{source: source}, {:ok, rows} ->
      with {:ok, module} <- Map.fetch(@sources, to_string(source.resource)),
           {:ok, %{version_number: current} = row} <-
             Ash.get(module, source.id, tenant: tenant, authorize?: false),
           true <- current == source.version_number do
        {:cont, {:ok, Map.put(rows, source.id, row)}}
      else
        _ -> {:halt, {:drift, "#{source.resource} #{source.id}"}}
      end
    end)
  end

  defp assignments(candidate, tenant) do
    with {:ok, binary} <- SnapshotBuilder.unseal(candidate, :assignments, tenant),
         {:ok, list} when is_list(list) <- Jason.decode(binary) do
      {:ok, list}
    else
      {:ok, _} -> {:error, :assignments_unreadable}
      {:error, %Jason.DecodeError{}} -> {:error, :assignments_unreadable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transact(changeset, snapshot, payload, rows, assignments, actor, tenant) do
    ids = payload["ids"]["tasks"]
    durations = payload["t_dur"]
    versioned = versioned_tasks(snapshot)

    {writable, excluded} =
      assignments
      |> Enum.filter(&(&1["kind"] == "task"))
      |> Enum.split_with(&MapSet.member?(versioned, &1["id"]))

    opts = [actor: actor, tenant: tenant]

    result =
      Ash.transaction(Task, fn ->
        Enum.each(writable, fn assignment ->
          case apply_one(assignment, rows, ids, durations, snapshot.effective_at, opts) do
            :ok -> :ok
            {:error, error} -> Ash.DataLayer.rollback(Task, error)
          end
        end)

        :ok
      end)

    case result do
      {:ok, :ok} ->
        Ash.Changeset.set_context(changeset, %{planning_excluded: length(excluded)})

      {:error, error} ->
        changeset
        |> Ash.Changeset.set_context(%{planning_apply: :refused})
        |> Ash.Changeset.add_error(
          field: :assignments,
          message: "apply refused: #{reason_text(error)}"
        )
    end
  end

  # Task sources that carry a version precondition (contingency C6).
  defp versioned_tasks(snapshot) do
    for %{role: role, source: %{version_number: v, id: id}} <- snapshot.inputs,
        role in [:task],
        is_integer(v),
        into: MapSet.new(),
        do: id
  end

  defp apply_one(
         %{"id" => id, "scheduled" => true, "start_slot" => slot},
         _rows,
         ids,
         durations,
         week_start,
         opts
       ) do
    index = Enum.find_index(ids, &(&1 == id))
    slots = index && Enum.at(durations, index)

    if is_integer(slots) do
      starts_at = Lowering.slot_to_datetime(week_start, slot)
      ends_at = DateTime.add(starts_at, slots * Lowering.slot_minutes() * 60, :second)

      case Task.schedule_mine(id, starts_at, ends_at, opts) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      {:error, :unknown_task}
    end
  end

  defp apply_one(%{"id" => id, "scheduled" => false}, rows, _ids, _durations, _week_start, opts) do
    case rows do
      %{^id => %{scheduled_start_at: %DateTime{}}} ->
        case Task.unschedule_mine(id, opts) do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      _ ->
        :ok
    end
  end

  defp apply_one(_other, _rows, _ids, _durations, _week_start, _opts),
    do: {:error, :bad_assignment}

  # ── after the transaction ──────────────────────────────────────────────────

  # The failure reason travels in the error text as well as the changeset context: an error
  # raised in `before_action` reaches this hook with the changeset as it entered the action.
  defp settle(changeset, {:error, error} = result, context) do
    candidate = changeset.data
    tenant = changeset.tenant
    text = reason_text(error)

    reason =
      cond do
        changeset.context[:planning_apply] -> changeset.context[:planning_apply]
        text =~ "a source changed since the snapshot" -> :drift
        text =~ "apply refused" -> :refused
        true -> nil
      end

    case reason do
      :drift ->
        Planning.mark_planning_candidate_stale(candidate, %{},
          actor: SystemActor.oban(),
          tenant: tenant
        )

      :refused ->
        Planning.reject_planning_candidate(candidate, %{}, actor: context.actor, tenant: tenant)

      _ ->
        :ok
    end

    result
  end

  defp settle(_changeset, result, _context), do: result

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text(%Ash.Changeset{errors: errors}),
    do: errors |> Enum.map(&reason_text/1) |> Enum.join("; ")

  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(_), do: "refused"
end
