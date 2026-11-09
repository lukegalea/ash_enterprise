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
    operator_id = actor_id(context.actor)
    subject_id = Ash.Changeset.get_attribute(changeset, :subject_id)
    approver_id = Ash.Changeset.get_attribute(changeset, :approver_id)
    minutes = Ash.Changeset.get_argument(changeset, :duration_minutes)

    cond do
      is_nil(operator_id) ->
        error(:operator_id, "must be a person")

      subject_id == operator_id ->
        error(:subject_id, "cannot be the operator")

      is_nil(approver_id) ->
        error(:approver_id, "is required")

      approver_id in [operator_id, subject_id] ->
        error(:approver_id, "must be someone other than the operator and the subject")

      not active?(subject_id) ->
        error(:subject_id, "must be an active user")

      not active?(approver_id) ->
        error(:approver_id, "must be an active user")

      not (is_integer(minutes) and minutes >= 1 and minutes <= BreakGlassSession.max_minutes()) ->
        error(
          :duration_minutes,
          "must be between 1 and #{BreakGlassSession.max_minutes()} minutes"
        )

      true ->
        :ok
    end
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
