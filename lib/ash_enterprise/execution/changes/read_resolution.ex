defmodule AshEnterprise.Execution.Changes.ReadResolution do
  @moduledoc """
  On `apply_resolution`: reads the decided resolution task and hands its outcome to the
  fragment, which applies it (`AshAgent.Invocation.Changes.ApplyResolution`).

  Runs in the update's transaction, before the fragment reads its arguments (a
  `before_action` hook prepended ahead of the fragment's). It refuses, so nothing is
  written, unless the row's latest resolution task is completed with one of
  `succeeded`, `failed` or `retry` by a person. This is action logic, not a policy
  check, so it may read.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution.Resolution

  @outcomes %{"succeeded" => :succeeded, "failed" => :failed, "retry" => :retry}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &read/1, prepend?: true)
  end

  defp read(changeset) do
    row = changeset.data

    case decision(row, changeset.tenant) do
      {:ok, outcome, decider_id} ->
        changeset
        |> Ash.Changeset.force_set_argument(:outcome, outcome)
        |> Ash.Changeset.force_set_argument(:decided_by_id, decider_id)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :outcome, message: message)
    end
  end

  defp decision(row, tenant) do
    case latest_task(row, tenant) do
      {:ok, %{status: :completed} = task} -> verdict(task)
      {:ok, _open_or_missing} -> {:error, "no decided resolution for this invocation"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp latest_task(row, tenant) do
    subject_type = to_string(row.__struct__)
    key = Resolution.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key and
        inserted_at >= ^row.resolution_requested_at
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: tenant)
  end

  defp verdict(%{outcome: outcome, decided_by_id: decider_id})
       when is_map_key(@outcomes, outcome) and not is_nil(decider_id) do
    if person?(decider_id),
      do: {:ok, Map.fetch!(@outcomes, outcome), decider_id},
      else: {:error, "the resolution was not decided by a person"}
  end

  defp verdict(_task),
    do: {:error, "the resolution task was completed without succeeded, failed or retry"}

  defp person?(id) do
    User
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists?(authorize?: false)
  end
end
