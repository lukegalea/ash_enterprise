defmodule AshEnterprise.Execution.Changes.Intervene do
  @moduledoc """
  An `AshEnterprise.Execution.Intervention`'s act, run as the person in the
  intervention's own transaction, before its row is written: the row records an act that
  happened, and an act that is refused writes nothing.

    * `:rerun`: `Invocation.rerun` on the invocation; the new row is the intervention's
      `rerun`.
    * `:cancel`: `Invocation.request_cancel` on the invocation.
    * `:resolve`: `HumanTask.settle` on the invocation's open resolution task, with the
      reason as the task's comment, then the `:apply_resolution` job for the invocation,
      so the outcome is applied now rather than at the next sweep.

  Each act first reads the invocation as the person, and refuses what
  `AshEnterprise.Execution.Recovery` does not offer for its status.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Invocation, Recovery}

  @impl true
  def init(opts) do
    if opts[:act] in [:rerun, :cancel, :resolve],
      do: {:ok, opts},
      else: {:error, "act must be :rerun, :cancel or :resolve"}
  end

  @impl true
  def change(changeset, opts, context) do
    act = opts[:act]

    changeset
    |> Ash.Changeset.force_change_attribute(:act, act)
    |> Ash.Changeset.before_action(fn changeset ->
      ash_opts = context |> Ash.Context.to_opts() |> Keyword.put(:tenant, changeset.tenant)

      with {:ok, invocation} <- invocation(changeset, ash_opts),
           {:ok, changeset} <- act(act, changeset, invocation, ash_opts) do
        changeset
      else
        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp invocation(changeset, opts) do
    case Ash.Changeset.get_attribute(changeset, :invocation_id) do
      nil ->
        {:error, :invocation_id, "is required"}

      id ->
        case Execution.get_invocation(id, Keyword.put(opts, :load, [:resolution_task])) do
          {:ok, invocation} ->
            {:ok, invocation}

          {:error, _not_readable} ->
            {:error, :invocation_id, "no invocation you can read has this id"}
        end
    end
  end

  defp act(:rerun, changeset, invocation, opts) do
    with :ok <- offered(Recovery.rerun(invocation)),
         {:ok, rerun} <-
           Invocation
           |> Ash.Changeset.for_create(:rerun, %{of: invocation.id}, opts)
           |> Ash.create() do
      {:ok, Ash.Changeset.force_change_attribute(changeset, :rerun_id, rerun.id)}
    end
  end

  defp act(:cancel, changeset, invocation, opts) do
    with :ok <- offered(Recovery.cancel(invocation)),
         {:ok, _cancelled} <- Execution.request_invocation_cancel(invocation, opts) do
      {:ok, changeset}
    end
  end

  defp act(:resolve, changeset, invocation, opts) do
    with :ok <- offered(Recovery.settle(invocation)),
         {:ok, task} <- open_task(invocation),
         {:ok, _outcome} <-
           HumanTask
           |> Ash.ActionInput.for_action(
             :settle,
             %{
               record_id: task.id,
               outcome: Ash.Changeset.get_attribute(changeset, :resolution),
               comment: Ash.Changeset.get_attribute(changeset, :reason)
             },
             opts
           )
           |> Ash.run_action() do
      {:ok, Ash.Changeset.after_action(changeset, &apply_now(&1, &2, invocation))}
    end
  end

  defp offered(:ok), do: :ok

  defp offered({:error, reason}),
    do: {:error, :invocation_id, "cannot be done now: " <> Recovery.explain(reason)}

  defp open_task(%{resolution_task: %{status: status} = task}) when status in [:open, :claimed],
    do: {:ok, task}

  defp open_task(_invocation),
    do: {:error, :invocation_id, "has no open task asking you to settle it"}

  # The decision is on the task; the `:apply_resolution` job applies it to the row.
  defp apply_now(_changeset, intervention, invocation) do
    %Oban.Job{} = AshOban.run_trigger(invocation, :apply_resolution)
    {:ok, intervention}
  end
end
