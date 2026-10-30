defmodule AshEnterprise.Execution.Changes.ReadApproval do
  @moduledoc """
  On `apply_decision`: reads the row's approval task and hands the fragment the outcome
  to apply (`AshAgent.Invocation.Changes.ApplyDecision`), never taking one from the
  caller.

  Runs in the update's transaction, before the fragment reads its arguments (a
  `before_action` hook prepended ahead of the fragment's). This is action logic, not a
  policy check, so it may read.

    * **Approved** by a person who may still approve
      (`AshEnterprise.Execution.Approval.approver_holds?/2`) and, under four eyes, is
      not the requester: `:approved`, with the decider. The fragment then checks that
      the approval still binds the request (its digest, recomputed from the row, the
      target as declared now and the subject as it stands now) and makes the row
      `ready`, or `stale`.
    * Approved by anyone else: `stale`, `error_code` `"approved_by_requester"` or
      `"approver_unauthorized"`. The approval is not the one asked for, so the row asks
      no further; the requester may ask again.
    * **Rejected**: `:rejected`.
    * The task expired, or `approval_expires_at` passed with no decision: `stale`,
      `"approval_expired"`. The task was cancelled: `stale`, `"approval_withdrawn"`.
    * Otherwise (still open) the update is refused and writes nothing.

  Whatever is applied, the task that decided it is recorded as `approval_task_id`.

  The fault point `:invocation_decision_applying` fires once the decision is read and
  before it is written, so a test can fail the application and check that the next
  sweep applies it (`AshEnterprise.Faults`; a no-op outside the test configuration).
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution.Approval
  alias AshEnterprise.Faults

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &read/1, prepend?: true)
  end

  defp read(changeset) do
    row = changeset.data

    case approval_task(row, changeset.tenant) do
      {:ok, task} ->
        case decision(row, task, DateTime.utc_now()) do
          {:ok, outcome, decider_id, error_code} ->
            Faults.point(:invocation_decision_applying)

            changeset
            |> Ash.Changeset.force_set_argument(:outcome, outcome)
            |> Ash.Changeset.force_set_argument(:decided_by_id, decider_id)
            |> Ash.Changeset.force_change_attributes(%{
              approval_task_id: task && task.id,
              error_code: error_code
            })

          {:error, message} ->
            Ash.Changeset.add_error(changeset, field: :outcome, message: message)
        end

      {:error, error} ->
        Ash.Changeset.add_error(changeset, field: :outcome, message: Exception.message(error))
    end
  end

  defp approval_task(row, tenant) do
    subject_type = to_string(row.__struct__)
    key = Approval.key()

    HumanTask
    |> Ash.Query.filter(
      subject_type == ^subject_type and subject_id == ^row.id and node_id == ^key
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: tenant)
  end

  defp decision(row, %{status: :completed, outcome: "approved", decided_by_id: decider}, _now) do
    cond do
      row.approval_mode == :four_eyes and decider == row.owner_id ->
        {:ok, :stale, nil, "approved_by_requester"}

      Approval.approver_holds?(row, decider) ->
        {:ok, :approved, decider, nil}

      true ->
        {:ok, :stale, nil, "approver_unauthorized"}
    end
  end

  defp decision(_row, %{status: :completed, outcome: "rejected", decided_by_id: decider}, _now),
    do: {:ok, :rejected, decider, "approval_rejected"}

  defp decision(_row, %{status: :completed, outcome: "expired"}, _now),
    do: {:ok, :stale, nil, "approval_expired"}

  defp decision(_row, %{status: :cancelled}, _now), do: {:ok, :stale, nil, "approval_withdrawn"}

  defp decision(row, _open_or_missing, now) do
    case row.approval_expires_at do
      %DateTime{} = at ->
        if DateTime.compare(at, now) == :gt,
          do: {:error, "no decision to apply yet"},
          else: {:ok, :stale, nil, "approval_expired"}

      nil ->
        {:error, "no decision to apply yet"}
    end
  end
end
