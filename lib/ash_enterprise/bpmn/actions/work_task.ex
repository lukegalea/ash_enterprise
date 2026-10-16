defmodule AshEnterprise.Bpmn.Actions.WorkTask do
  @moduledoc """
  `HumanTask.claim_task` / `.complete_task` / `.delegate_task`: the task
  board's acts (`AshEnterpriseWeb.A2ui.TaskBoardUI`), as the clicking person.

  Each reads the task **as the actor** (their policies; a task they cannot
  read is "not found"), checks who may do this (`AshEnterprise.Bpmn.Candidacy`)
  and only then hands the write to the process engine:

    * **claim** — an open task the actor is a candidate for (directly or
      through a team). The engine's `AshBpmn.claim_task/2` accepts only
      user-typed candidate rows, so the claim is the engine's own `:claim`
      action plus the `:task_claimed` event it would have recorded.
    * **complete** — a task the actor has claimed, with an outcome and an
      optional comment, through `AshBpmn.complete_task/2` (which cancels the
      task's timers and advances its token).
    * **delegate** — a task the actor has claimed, to another person by
      email (read as the actor, so only someone they can see) who is
      themselves one of the task's candidates, through
      `AshBpmn.delegate_task/2`, which records who it came from.

  Delegation never widens who may decide a task. Maker-checker lives in the
  materialised candidate set — the excluded requester simply has no
  candidate row — and the person a task is delegated to becomes its
  assignee, who completes it without a further candidacy check. So the
  delegatee must already be a candidate (directly or through a team),
  checked against *their* `ActorContext`; anyone else, the excluded maker
  included, is refused.

  A claim is guarded in the database, not only against the row read at the
  start of the action: the update is filtered on `status == :open`, so of
  two people claiming at once exactly one wins and the other is refused
  (`Ash.Error.Changes.StaleRecord`), and the claim and its `:task_claimed`
  event are written in one transaction.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Expr
  require Ash.Query

  alias AshBpmn.Scope
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{Candidacy, HumanTask, ProcessEvent}
  alias AshEnterprise.Security.ActorContext

  @impl true
  def run(input, opts, context) do
    op = Keyword.fetch!(opts, :op)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, task} <- Ash.get(HumanTask, input.arguments.record_id, ash_opts) do
      case work(op, task, input.arguments, context.actor, ash_opts) do
        {:ok, message} -> {:ok, message}
        {:error, %{__exception__: true} = error} -> {:error, error}
        {:error, reason} -> {:error, invalid(reason, field(op))}
      end
    end
  end

  # A refusal is reported on the field the person typed into, so the board's
  # prompt shows it under the input; a claim has no prompt.
  defp field(:delegate), do: :delegate_to
  defp field(:complete), do: :outcome
  defp field(:claim), do: :record_id

  defp work(:claim, task, _arguments, actor, opts) do
    with :ok <- status(task, :open),
         :ok <- Candidacy.candidate(task, actor, opts) do
      claim(task, actor)
    end
  end

  defp work(:complete, task, arguments, actor, _opts) do
    with :ok <- status(task, :claimed),
         :ok <- Candidacy.assignee(task, actor),
         {:ok, _completed} <-
           AshBpmn.complete_task(task,
             outcome: arguments.outcome,
             comment: arguments[:comment],
             actor: actor,
             tenant: task.organization_id
           ) do
      {:ok, "Completed (#{arguments.outcome}) — #{task.name}."}
    end
  end

  defp work(:delegate, task, arguments, actor, opts) do
    with :ok <- status(task, :claimed),
         :ok <- Candidacy.assignee(task, actor),
         {:ok, to} <- delegatee(task, arguments.delegate_to, actor, opts),
         {:ok, _delegated} <-
           AshBpmn.delegate_task(task,
             to_principal: %{type: :user, id: to.id},
             actor: actor,
             tenant: task.organization_id
           ) do
      {:ok, "Delegated to #{to.email} — #{task.name}."}
    end
  end

  # The claim, guarded in the database and written with its event.
  defp claim(task, actor) do
    engine = task |> Scope.from_record(actor: actor) |> Scope.engine()

    task
    |> Ash.Changeset.for_update(
      :claim,
      %{assignee_type: :user, assignee_id: actor.id},
      engine
    )
    # The engine's own guard reads the struct this action started from; this
    # one is in the UPDATE's WHERE clause, so a concurrent claim that landed
    # first leaves nothing to update and this one is refused.
    |> Ash.Changeset.filter(Ash.Expr.expr(status == :open))
    |> Ash.Changeset.after_action(fn _changeset, claimed ->
      # Inside the claim's transaction: no claim without its event.
      with {:ok, _event} <- record_claim(claimed, actor, engine), do: {:ok, claimed}
    end)
    |> Ash.update(engine)
    |> case do
      {:ok, _claimed} -> {:ok, "Claimed — #{task.name}."}
      {:error, error} -> {:error, error}
    end
  end

  defp record_claim(claimed, actor, engine) do
    ProcessEvent.create(
      %{
        instance_id: claimed.instance_id,
        token_id: claimed.token_id,
        node_id: claimed.node_id,
        task_id: claimed.id,
        kind: :task_claimed,
        data: %{"assignee_id" => actor.id}
      },
      engine
    )
  end

  defp status(%{status: status}, status), do: :ok
  defp status(%{status: :open}, :claimed), do: {:error, "claim this task first"}
  defp status(%{status: :claimed}, :open), do: {:error, "this task is already claimed"}
  defp status(_task, _wanted), do: {:error, "this task has already been decided"}

  # The person to delegate to, as the actor may see them: an address they
  # cannot read is the same answer as one that does not exist. They must be
  # one of the task's candidates themselves: the hand-off makes them its
  # assignee, and an assignee decides without a further candidacy check, so
  # anyone else — the requester maker-checker excluded, a colleague with
  # every task grant — would be a way around the candidate set.
  defp delegatee(task, email, actor, opts) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %User{id: id}} when id == actor.id ->
        {:error, "you already hold this task"}

      {:ok, %User{} = user} ->
        eligible(task, user, email, opts)

      _not_found ->
        {:error, "no one you can see has the address #{email}"}
    end
  end

  # A candidate, who can also read the task (else it would be stranded with
  # them: they could never open it to complete it).
  defp eligible(task, user, email, opts) do
    tenant = opts[:tenant] || task.organization_id
    delegatee = ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

    cond do
      candidate(task, delegatee) != :ok ->
        {:error, "#{email} is not one of this task's approvers"}

      not Ash.can?({task, :read}, delegatee, tenant: tenant) ->
        {:error, "#{email} cannot see this task, so could not complete it"}

      true ->
        {:ok, user}
    end
  end

  # Candidacy as the delegatee: their principal ids (them and their teams)
  # from their own context. The candidate rows are read as the engine, as its
  # own claim check reads them: whether someone is in a task's candidate set
  # is a fact about the task, not about what either person may browse.
  defp candidate(task, delegatee) do
    engine = task |> Scope.from_record(actor: delegatee) |> Scope.engine()
    Candidacy.candidate(task, delegatee, engine)
  end

  defp invalid(reason, field) do
    Ash.Error.Changes.InvalidArgument.exception(field: field, message: to_string(reason))
  end
end
