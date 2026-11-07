defmodule AshEnterprise.Bpmn.Actions.SettleTask do
  @moduledoc """
  `HumanTask.resolve`: a person settles an invocation's unknown outcome from the task
  that asks them to (the approvals surface, ACP `_a2ui/action` on it), and the act is
  the recovery surface's own: `AshEnterprise.Execution.Intervention`'s `resolve`, run as
  them, which decides the task through `HumanTask.settle` and records who settled it,
  how and why in the same transaction. So a settlement made from the task is in the
  recovery page's "What people did" and in the trace like any other, and is refused
  without a reason.

  The task is read as the person first; only a resolution task
  (`AshEnterprise.Execution.Resolution`) about an invocation is settled here.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Bpmn.{HumanTask, Outcomes}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Invocation, Resolution}

  @invocation to_string(Invocation)

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    %{record_id: id, outcome: outcome, comment: reason} = input.arguments

    with {:ok, task} <- Ash.get(HumanTask, id, opts),
         :ok <- settles_an_invocation(task),
         {:ok, _intervention} <-
           Execution.resolve_invocation(task.subject_id, outcome, reason, opts) do
      {:ok, "Settled as #{outcome} — #{task.name}."}
    else
      {:error, error} -> {:error, Outcomes.refusal(error, :record_id)}
    end
  end

  defp settles_an_invocation(%{subject_type: @invocation} = task),
    do: Resolution.check(task, :resolve)

  defp settles_an_invocation(_task),
    do: {:error, "only a task settling an invocation's unknown outcome is resolved"}
end
