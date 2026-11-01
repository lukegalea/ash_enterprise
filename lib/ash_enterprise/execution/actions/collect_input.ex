defmodule AshEnterprise.Execution.Actions.CollectInput do
  @moduledoc """
  The `collect_input` action, run by the invocation's `:collect_input` trigger: a person
  answered an agent's question (`AshEnterprise.Execution.HumanInput`), or its task was
  cancelled, and the `dispatched` invocation is completed from the task with
  `complete_external`.

    * Answered (completed `answered` by a person, through `HumanTask.answer`): the
      invocation succeeds with `result` `%{"answer" => answer}`, which the run's next
      step reads as the tool call's result.
    * Expired unanswered (the engine closes the task at the dispatch's deadline): it
      fails as `:timeout`, `"deadline_passed"`, as the `:reconcile` sweep would fail it.
    * Cancelled, or completed any other way: it fails as `:rejected`, `"input_withdrawn"`
      or `"input_not_answered"`.

  The completion is filtered on the status and epoch it read, so of two collections one
  writes and the other ends `:superseded`; a row that is no longer `dispatched`, or a
  task still open, is `:skipped`. Its own write wakes the run
  (`AshAgent.Run.Changes.Wake`). Reading the task is action logic, not a policy check,
  so it may read.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution.HumanInput

  @outcomes [:succeeded, :failed, :skipped, :superseded]

  @doc "Every outcome `collect_input` returns."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @impl true
  def run(input, _opts, context) do
    primary_key = input.arguments.primary_key
    id = Map.get(primary_key, "id") || Map.get(primary_key, :id)
    opts = Ash.Context.to_opts(context)

    case Ash.get(input.resource, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %{status: :dispatched} = row} -> collect(row, opts)
      {:ok, _gone_or_moved_on} -> {:ok, :skipped}
      {:error, error} -> {:error, error}
    end
  end

  defp collect(row, opts) do
    if row.effect_system == HumanInput.effect_system() do
      case task(row) do
        {:ok, %{status: :completed} = task} -> complete(row, answer(task), opts)
        {:ok, %{status: :cancelled}} -> complete(row, failed("input_withdrawn"), opts)
        {:ok, _open_or_missing} -> {:ok, :skipped}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, :skipped}
    end
  end

  defp task(row) do
    subject_type = to_string(row.__struct__)
    key = HumanInput.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: row.organization_id)
  end

  defp answer(%{outcome: "answered", decided_by_id: decider_id, comment: answer})
       when is_binary(decider_id) and is_binary(answer) do
    if person?(decider_id),
      do: %{outcome: :succeeded, via: "human_task", result: %{"answer" => answer}},
      else: failed("input_not_answered")
  end

  defp answer(%{outcome: "expired"}), do: failed(:timeout, "deadline_passed")
  defp answer(_task), do: failed("input_not_answered")

  defp failed(class \\ :rejected, code),
    do: %{outcome: :failed, via: "human_task", failure_class: class, error_code: code}

  defp complete(row, input, opts) do
    row
    |> Ash.Changeset.for_update(:complete_external, input, opts)
    |> Ash.update()
    |> case do
      {:ok, done} -> {:ok, done.status}
      {:error, error} -> if stale?(error), do: {:ok, :superseded}, else: {:error, error}
    end
  end

  defp person?(id) do
    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_error), do: false
end
