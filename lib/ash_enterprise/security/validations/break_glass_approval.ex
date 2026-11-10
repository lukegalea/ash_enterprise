defmodule AshEnterprise.Security.Validations.BreakGlassApproval do
  @moduledoc """
  The terms on which a break-glass session is approved:

    * the actor is a person, and is the approver the session names;
    * the approver is neither the operator nor the subject;
    * the session is active, not yet approved, and not past `expires_at`;
    * the approver is still an active user.

  An approval that fails any of these leaves the session unapproved, and an
  unapproved session is never live.
  """
  use Ash.Resource.Validation

  alias AshEnterprise.Accounts.User

  @impl true
  def validate(changeset, _opts, context) do
    session = changeset.data
    actor_id = actor_id(context.actor)

    [
      &named_approver/2,
      &distinct_parties/2,
      &pending/2,
      &approver_active/2
    ]
    |> Enum.find_value(:ok, & &1.(session, actor_id))
  end

  defp named_approver(%{approver_id: id}, id) when is_binary(id), do: nil
  defp named_approver(_, _), do: error("only the approver the session names can approve it")

  defp distinct_parties(%{approver_id: id, operator_id: operator, subject_id: subject}, _)
       when id in [operator, subject],
       do: error("the operator and the subject cannot approve")

  defp distinct_parties(_, _), do: nil

  defp pending(session, _) do
    cond do
      session.lifecycle_status != :active ->
        error("the session has ended")

      not is_nil(session.approved_at) ->
        error("the session is already approved")

      DateTime.compare(DateTime.utc_now(), session.expires_at) != :lt ->
        error("the session has expired")

      true ->
        nil
    end
  end

  defp approver_active(%{approver_id: id}, _) do
    case Ash.get(User, id, authorize?: false, not_found_error?: false) do
      {:ok, %{lifecycle_status: :active}} -> nil
      _ -> error("the approver must be an active user")
    end
  end

  defp error(message), do: {:error, field: :approver_id, message: message}

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_), do: nil
end
