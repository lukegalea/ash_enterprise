defmodule AshEnterprise.Agents.BriefDecision do
  @moduledoc """
  Approve or reject a morning brief from a surface — through the brief's
  approval task, never around it.

  The Today surface lists `MorningBrief.approve` / `.reject` as its row actions
  (the allowlist entries and button labels), but declares `via` this module, so
  a click never invokes those update actions directly: it finds the open
  `morning.brief` approval task whose subject is the brief — read as the actor
  — and decides it with `HumanTask.approve` / `.reject`, which checks the
  actor's candidacy and completes the task through the process engine. The
  process's own service tasks then record the outcome on the brief (ADR 0015).
  """

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask

  @doc "The `via` entry point: `context` per `AshA2ui`'s row-action delegation contract."
  @spec decide(map(), String.t()) :: :ok | {:ok, term()} | {:error, term()}
  def decide(%{record: brief, actor: actor, tenant: tenant}, outcome) do
    opts = [actor: actor, tenant: tenant || brief.organization_id]

    with {:ok, task} <- open_task(brief, opts) do
      HumanTask
      |> Ash.ActionInput.for_action(action(outcome), %{record_id: task.id}, opts)
      |> Ash.run_action(opts)
    end
  end

  @doc "The open approval task for `brief`, read as the actor in `opts`."
  def open_task(brief, opts) do
    subject_type = to_string(brief.__struct__)

    HumanTask
    |> Ash.Query.for_read(:awaiting_me, %{}, opts)
    |> Ash.Query.filter(
      instance.subject_type == ^subject_type and instance.subject_id == ^brief.id
    )
    |> Ash.read(opts)
    |> case do
      {:ok, [task | _]} ->
        {:ok, task}

      {:ok, []} ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :status,
           message: "this brief has no approval waiting on you"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp action("approved"), do: :approve
  defp action("rejected"), do: :reject
end
