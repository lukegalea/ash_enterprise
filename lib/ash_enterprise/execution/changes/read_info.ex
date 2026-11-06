defmodule AshEnterprise.Execution.Changes.ReadInfo do
  @moduledoc """
  On `provide_info`: lets the row go back to its approver only once the requester has
  answered (`AshEnterprise.Execution.InfoRequest`).

  Reads the row's latest information task with the engine's authority, in the update's
  transaction (a `before_action` hook). Completed as `answered`: the update goes ahead,
  and `AshEnterprise.Execution.Changes.RequestApproval` opens the next approval task in
  the same transaction. Anything else (still open, cancelled, missing, or completed with
  another outcome) refuses the update, so it writes nothing: an answer that is not there
  is never read as one.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution.InfoRequest

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &read/1, prepend?: true)
  end

  defp read(changeset) do
    case info_task(changeset.data, changeset.tenant) do
      {:ok, %{status: :completed, outcome: "answered"}} ->
        changeset

      {:ok, _unanswered} ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "the requester has not answered"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, field: :status, message: Exception.message(error))
    end
  end

  defp info_task(row, tenant) do
    subject_type = to_string(row.__struct__)
    key = InfoRequest.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: tenant)
  end
end
