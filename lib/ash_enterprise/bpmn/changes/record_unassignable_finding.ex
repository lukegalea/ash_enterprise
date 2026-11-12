defmodule AshEnterprise.Bpmn.Changes.RecordUnassignableFinding do
  @moduledoc """
  Raises a compliance finding when the engine records that a task's candidates, minus its
  exclusions, left nobody (`:no_eligible_candidate`, from
  `AshEnterprise.Process.AssignmentResolver.no_eligible_candidate/2`).

  ## Why an `ash_compliance` finding

  It is the record the compliance suite already reads, resolves and exports, and
  `AshCompliance.Processes.Overdue` already files process exceptions there under the same
  rules: the grain is `{organization, control, subject_type, task id}` and the status is
  `:unknown`, because a review nobody could route is a control whose operation is not
  established, not a failed control. A host table would be a second place an auditor has to
  know to look.

  The control is the one the process's pack names (`AshEnterprise.Bpmn.Packs.controls_for_process/1`:
  `CC6.3` for the role-change review), or `process:unassignable` for a process no pack
  names, so the finding cannot disappear. Severity is `:high` when nobody can act on the task
  and `:medium` when it was escalated to the fallback.

  Written in the event's `after_action`, so the finding commits with the task and its event
  or not at all; a write that fails fails the step, and the engine retries it. The finding is
  not resolved when the task is later decided: it records that the review could not be
  routed to its own reviewers, which stays true.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance, Packs}
  alias AshEnterprise.Process.DefinitionLoader

  @subject_type "task_unassignable"
  @gap "no_eligible_candidate"
  @unclassified "process:unassignable"

  @doc "The finding subject type these findings are filed under."
  def subject_type, do: @subject_type

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :kind) == :no_eligible_candidate do
      Ash.Changeset.after_action(changeset, &file_after_action/2)
    else
      changeset
    end
  end

  defp file_after_action(_changeset, event) do
    case file(event) do
      :ok -> {:ok, event}
      {:error, error} -> {:error, error}
    end
  end

  defp file(%{organization_id: org, task_id: task_id} = event)
       when is_binary(org) and is_binary(task_id) do
    opts = [authorize?: false, tenant: org]
    task = Ash.get!(HumanTask, task_id, opts)
    now = DateTime.utc_now()
    data = event.data || %{}
    explanation = explanation(task, data)
    severity = if data["escalated"] == true, do: :medium, else: :high

    task
    |> process_key(org, opts)
    |> Packs.controls_for_process()
    |> case do
      [] -> [@unclassified]
      controls -> controls
    end
    |> Enum.reduce_while(:ok, fn control, :ok ->
      case file_one(org, control, task_id, severity, explanation, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A standalone approval with no tenant or task cannot be filed against anything; the
  # engine's event is still there.
  defp file(_event), do: :ok

  defp file_one(org, control, task_id, severity, explanation, now) do
    grain = %{
      organization_id: org,
      control_id: control,
      subject_type: @subject_type,
      subject_id: task_id
    }

    with {:ok, row} <- AshCompliance.Domain.upsert_finding_grain(grain, authorize?: false) do
      first_seen = if row.first_seen_at, do: [], else: [{:set, :first_seen_at, now}]

      ops =
        first_seen ++
          [
            {:set, :status, :unknown},
            {:set, :severity, severity},
            {:set, :gap, @gap},
            {:set, :last_seen_at, now},
            {:set, :resolved_at, nil},
            {:set, :explanation, explanation}
          ]

      case AshCompliance.Domain.apply_finding_ops(row, ops, authorize?: false) do
        {:ok, _finding} -> :ok
        error -> error
      end
    end
  end

  defp process_key(%{instance_id: nil}, _org, _opts), do: nil

  defp process_key(%{instance_id: instance_id}, org, opts) do
    with {:ok, instance} <- Ash.get(Instance, instance_id, opts),
         {:ok, definition} <-
           DefinitionLoader.load(Definition, instance.definition_id, instance, %{tenant: org}) do
      definition.key
    else
      _ -> nil
    end
  end

  defp explanation(task, data) do
    candidates = data["candidates"] || 0
    fallback = data["fallback"] || 0

    routed =
      if data["escalated"] == true,
        do: "escalated to #{fallback} fallback #{plural(fallback, "reviewer")}",
        else: "the fallback named nobody, so nobody can act on it"

    failed = if data["error"], do: " The fallback failed: #{data["error"]}.", else: ""

    "No eligible reviewer for task #{task.id} (#{task.name}): " <>
      "its #{candidates} #{plural(candidates, "candidate")} #{if candidates == 1, do: "was", else: "were"} " <>
      "all excluded; #{routed}.#{failed}"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
