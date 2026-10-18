defmodule AshEnterprise.Bpmn.Actions.DecideTask do
  @moduledoc """
  `HumanTask.approve` / `HumanTask.reject`: decide one task the actor may
  act on, through the process engine (ADR 0015 — approvals live in Ash,
  decisions go through the engine).

  The task is read as the actor (a candidate reads it through
  `TaskCandidacy`), and `AshBpmn.complete_task/2` decides who may complete
  it: an **open** task any candidate it does not exclude (the decision claims
  it on the way), a **claimed** one only its holder. Anyone else is refused
  as `Forbidden` and nothing is written. The engine then completes the task
  with the actor as `decided_by`, cancels its timers and advances the token,
  so the process's own service tasks do the work the outcome routes to.
  Nothing here writes the subject directly.

  Two host rules sit on top:

    * **Declared outcomes.** `approved` / `rejected` must be outcomes the
      task's step declares (`AshEnterprise.Bpmn.Outcomes`), except on a
      steward-decision task;
    * **Steward decisions.** On a steward-decision task, Approve confirms the
      match and Reject rejects it: the verdict is recorded on the match
      candidate as the person, and that completes the task in the same
      transaction (`AshEnterprise.Mdm.StewardTask`).
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.{HumanTask, Outcomes}
  alias AshEnterprise.Mdm.StewardTask

  @impl true
  def run(input, opts, context) do
    outcome = Keyword.fetch!(opts, :outcome)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, task} <- Ash.get(HumanTask, input.arguments.record_id, ash_opts) do
      case decide(task, outcome, input.arguments[:comment], context.actor, ash_opts) do
        {:ok, message} -> {:ok, message}
        {:error, error} -> {:error, Outcomes.refusal(error, :record_id)}
      end
    end
  end

  defp decide(task, outcome, comment, actor, opts) do
    case StewardTask.candidate_id(task) do
      {:ok, candidate_id} ->
        StewardTask.decide(task, candidate_id, outcome, comment, opts)

      :none ->
        with :ok <- Outcomes.check(task, outcome, opts),
             {:ok, _completed} <-
               AshBpmn.complete_task(task,
                 outcome: outcome,
                 comment: comment,
                 actor: actor,
                 tenant: task.organization_id
               ) do
          {:ok, "#{verb(outcome)} — #{task.name}."}
        end
    end
  end

  defp verb("approved"), do: "Approved"
  defp verb("rejected"), do: "Rejected"
  defp verb(other), do: String.capitalize(other)
end
