defmodule AshEnterprise.Bpmn.Actions.DecideTask do
  @moduledoc """
  `HumanTask.approve` / `HumanTask.reject`: decide one task the actor is a
  candidate for, through the process engine (ADR 0015 — approvals live in Ash,
  decisions go through the engine).

  The only path in: the task is read as the actor (their policies), and who
  may decide it depends on its state (`AshEnterprise.Bpmn.Candidacy`):

    * **open** — any candidate: a materialised `TaskCandidate` row for the
      actor or one of their teams, the same rows `/app/tasks` joins on. The
      decision claims it implicitly.
    * **claimed** — only its assignee (they claimed it, or it was delegated
      to them). Another candidate — the person who delegated it away
      included — is refused, as the task board refuses them Complete: once
      someone holds a task, only they decide it.

  Only then is
  `AshBpmn.complete_task/2` called — which records the implicit claim,
  completes the task with the actor as `decided_by`, cancels its timers and
  advances the token, so the process's own service tasks do the work the
  outcome routes to. Nothing here writes the subject directly.

  `AshBpmn.complete_task/2` itself does not check candidacy; this module is
  where that check lives for the surfaces and ACP.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.{Candidacy, HumanTask}

  @impl true
  def run(input, opts, context) do
    outcome = Keyword.fetch!(opts, :outcome)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, task} <- Ash.get(HumanTask, input.arguments.record_id, ash_opts),
         :ok <- may_decide(task, context.actor, ash_opts),
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

  defp may_decide(%{status: :open} = task, actor, opts),
    do: Candidacy.candidate(task, actor, opts)

  defp may_decide(%{status: :claimed} = task, actor, _opts), do: Candidacy.assignee(task, actor)
  defp may_decide(_task, _actor, _opts), do: {:error, "this task has already been decided"}

  defp verb("approved"), do: "Approved"
  defp verb("rejected"), do: "Rejected"
  defp verb(other), do: String.capitalize(other)

  defp invalid(reason) do
    Ash.Error.Changes.InvalidArgument.exception(field: :record_id, message: to_string(reason))
  end
end
