defmodule AshEnterprise.Bpmn.Actions.DecideTask do
  @moduledoc """
  `HumanTask.approve` / `HumanTask.reject`: decide one task the actor is a
  candidate for, through the process engine (ADR 0015 — approvals live in Ash,
  decisions go through the engine).

  The only path in: the task is read as the actor (their policies), candidacy
  is checked against the materialised `TaskCandidate` rows for the actor and
  their teams (the same rows `/app/tasks` joins on), and only then is
  `AshBpmn.complete_task/2` called — which records the implicit claim,
  completes the task with the actor as `decided_by`, cancels its timers and
  advances the token, so the process's own service tasks do the work the
  outcome routes to. Nothing here writes the subject directly.

  `AshBpmn.complete_task/2` itself does not check candidacy; this module is
  where that check lives for the surfaces and ACP.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Security.ActorContext

  @impl true
  def run(input, opts, context) do
    outcome = Keyword.fetch!(opts, :outcome)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, task} <- Ash.get(HumanTask, input.arguments.record_id, ash_opts),
         :ok <- undecided(task),
         :ok <- candidate(task, context.actor, ash_opts),
         {:ok, _completed} <-
           AshBpmn.complete_task(task,
             outcome: outcome,
             comment: input.arguments[:comment],
             actor: context.actor,
             tenant: task.organization_id
           ) do
      {:ok, "#{verb(outcome)} — #{task.name}."}
    else
      {:error, %{__exception__: true} = error} -> {:error, error}
      {:error, reason} -> {:error, invalid(reason)}
    end
  end

  defp undecided(%{status: status}) when status in [:open, :claimed], do: :ok
  defp undecided(_task), do: {:error, "this task has already been decided"}

  defp candidate(task, actor, opts) do
    principal_ids = ActorContext.for_actor(actor).principal_ids

    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id and principal_id in ^principal_ids)
    |> Ash.exists?(opts)
    |> case do
      true -> :ok
      false -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp verb("approved"), do: "Approved"
  defp verb("rejected"), do: "Rejected"
  defp verb(other), do: String.capitalize(other)

  defp invalid(reason) do
    Ash.Error.Changes.InvalidArgument.exception(field: :record_id, message: to_string(reason))
  end
end
