defmodule AshEnterprise.Bpmn.Actions.WorkTask do
  @moduledoc """
  `HumanTask.claim_task` / `.complete_task` / `.delegate_task`: the task
  board's acts (`AshEnterpriseWeb.A2ui.TaskBoardUI`), as the clicking person.

  Each reads the task **as the actor** (a task they cannot read is "not
  found"; a candidate reads it through `TaskCandidacy`) and hands the act to
  the process engine, which decides who may do it (`AshBpmn.Candidacy`):

    * **claim** — `AshBpmn.claim_task/2`: an open task the actor (or one of
      their teams) is a candidate for and that does not exclude them. The
      claim and its `:task_claimed` event are one transaction, guarded in the
      UPDATE, so of two concurrent claims exactly one wins.
    * **complete** — a task the actor holds (an open one is claimed first:
      the board's Complete is the holder's act), with one of the outcomes its
      step declares (`AshEnterprise.Bpmn.Outcomes`) and an optional comment.
      A steward-decision task records the verdict on its match candidate
      instead, which completes the task in the same transaction
      (`AshEnterprise.Mdm.StewardTask`); any other task goes through
      `AshBpmn.complete_task/2`.
    * **delegate** — `AshBpmn.delegate_task/2`: a task the actor holds, to
      another person, picked from the task's `delegate_candidates`. The engine
      requires the delegate to be one of the task's candidates and not
      excluded from it, so delegation never widens who may decide a task; the
      delegate then reads it through their own candidacy.

  What stays here is the host's part: naming the person picked (an id that
  is no one reads the same as one that is not a candidate), the
  declared-outcome check and the steward mapping. The engine's refusals
  (`ArgumentError`) come back as `Forbidden`, so a click on a task that is not
  the person's reads "not authorized".
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{HumanTask, Outcomes}
  alias AshEnterprise.Mdm.StewardTask

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, task} <- Ash.get(HumanTask, input.arguments.record_id, ash_opts) do
      case work(op, task, input.arguments, context.actor, ash_opts) do
        {:ok, message} -> {:ok, message}
        {:error, error} -> {:error, Outcomes.refusal(error, field(op))}
      end
    end
  end

  # A refusal of the person's input is reported on the field they typed
  # into, so the board's prompt shows it under the input; a claim has none.
  defp field(:delegate), do: :delegate_to_id
  defp field(:complete), do: :outcome
  defp field(:claim), do: :record_id

  defp work(:claim, task, _arguments, actor, _opts) do
    with {:ok, _claimed} <-
           AshBpmn.claim_task(task, actor: actor, tenant: task.organization_id) do
      {:ok, "Claimed — #{task.name}."}
    end
  end

  defp work(:complete, task, arguments, actor, opts) do
    outcome = to_string(arguments.outcome)

    with :ok <- claimed(task),
         :ok <- Outcomes.check(task, outcome, opts) do
      complete(task, outcome, arguments[:comment], actor, opts)
    end
  end

  defp work(:delegate, task, arguments, actor, opts) do
    with {:ok, to} <- delegatee(arguments.delegate_to_id, actor, opts),
         {:ok, _delegated} <- delegate(task, to, actor) do
      {:ok, "Delegated to #{to.email} — #{task.name}."}
    end
  end

  defp delegate(task, to, actor) do
    task
    |> AshBpmn.delegate_task(
      to_principal: %{type: :user, id: to.id},
      actor: actor,
      tenant: task.organization_id
    )
    |> case do
      # The engine refuses a delegate outside the candidate set (or excluded
      # from it: maker-checker) with this sentence; it is about the person
      # picked, so it is answered under the picker, not as Forbidden.
      {:error, %ArgumentError{message: "the delegate " <> _}} ->
        {:error, not_a_candidate()}

      other ->
        other
    end
  end

  # The board's Complete is the holder's act: an open task is claimed first
  # (Approvals decides an open task in one step, through `DecideTask`).
  defp claimed(%{status: :claimed}), do: :ok
  defp claimed(%{status: :open}), do: {:error, "claim this task first"}
  defp claimed(_task), do: {:error, "this task has already been decided"}

  defp complete(task, outcome, comment, actor, opts) do
    case StewardTask.candidate_id(task) do
      {:ok, candidate_id} ->
        StewardTask.decide(task, candidate_id, outcome, comment, opts)

      :none ->
        with {:ok, _completed} <-
               AshBpmn.complete_task(task,
                 outcome: outcome,
                 comment: comment,
                 actor: actor,
                 tenant: task.organization_id
               ) do
          {:ok, "Completed (#{outcome}) — #{task.name}."}
        end
    end
  end

  # The person to delegate to, by id. Looked up with the system's authority,
  # so delegating needs no grant on users (a steward holds none): whether
  # they may take the task is the engine's candidacy check, and every refusal
  # reads the same — an id that is no one, someone in another tenant, or
  # someone who is not a candidate are one answer, so the action is not a way
  # to learn who has an account.
  defp delegatee(id, %{id: id}, _opts), do: {:error, "you already hold this task"}

  defp delegatee(id, _actor, _opts) do
    case Ash.get(User, id, authorize?: false, not_found_error?: false) do
      {:ok, %User{} = user} -> {:ok, user}
      _not_found -> {:error, not_a_candidate()}
    end
  end

  defp not_a_candidate, do: "that person is not one of this task's approvers"
end
