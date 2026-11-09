defmodule AshEnterprise.Security.Validations.BreakGlassTerms do
  @moduledoc """
  The terms a break-glass session must meet before a row exists:

    * the operator is a person (the actor) and is not the subject;
    * the approver exists, is active, and is neither the operator nor the subject;
    * the subject exists and is active;
    * the duration is between 1 and `BreakGlassSession.max_minutes/0` minutes.

  The reason's length is the attribute's constraint.
  """
  use Ash.Resource.Validation

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Security.BreakGlassSession

  @impl true
  def validate(changeset, _opts, context) do
    terms = %{
      operator_id: actor_id(context.actor),
      subject_id: Ash.Changeset.get_attribute(changeset, :subject_id),
      approver_id: Ash.Changeset.get_attribute(changeset, :approver_id),
      minutes: Ash.Changeset.get_argument(changeset, :duration_minutes)
    }

    [&parties/1, &approver/1, &activity/1, &duration/1]
    |> Enum.find_value(:ok, & &1.(terms))
  end

  defp parties(%{operator_id: nil}), do: error(:operator_id, "must be a person")

  defp parties(%{operator_id: id, subject_id: id}),
    do: error(:subject_id, "cannot be the operator")

  defp parties(_), do: nil

  defp approver(%{approver_id: nil}), do: error(:approver_id, "is required")

  defp approver(%{approver_id: id, operator_id: operator, subject_id: subject})
       when id in [operator, subject],
       do: error(:approver_id, "must be someone other than the operator and the subject")

  defp approver(_), do: nil

  defp activity(%{subject_id: subject, approver_id: approver}) do
    cond do
      not active?(subject) -> error(:subject_id, "must be an active user")
      not active?(approver) -> error(:approver_id, "must be an active user")
      true -> nil
    end
  end

  defp duration(%{minutes: minutes}) do
    max = BreakGlassSession.max_minutes()

    if is_integer(minutes) and minutes >= 1 and minutes <= max,
      do: nil,
      else: error(:duration_minutes, "must be between 1 and #{max} minutes")
  end

  defp error(field, message), do: {:error, field: field, message: message}

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_), do: nil

  defp active?(id) when is_binary(id) do
    match?(
      {:ok, %{lifecycle_status: :active}},
      Ash.get(User, id, authorize?: false, not_found_error?: false)
    )
  end

  defp active?(_), do: false
end
