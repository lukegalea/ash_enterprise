defmodule AshEnterprise.Accounts.Offboarding.Changes.RevokeLeaverCredentials do
  @moduledoc """
  The `revoke` update of `AshEnterprise.Accounts.Offboarding`: in the update's transaction,
  looks at the leaver again and, while they are still inactive, revokes every stored token
  still live for them and archives every API key they still have, recording how many.

  A leaver active again by now is not touched: the row records `reactivated`, and their
  tokens and keys, including any issued since the reactivation, stay as they are.

  The deactivation has already revoked the tokens stored when it ran
  (`AshEnterprise.Accounts.Changes.RevokeTokensOnDeactivation`). What this finds live is a
  token stored after it, which is why the count is usually zero. API keys are not revoked
  by the deactivation: they stop working while their owner is inactive and would work again
  on a reactivation, so this is the step that ends them.

  Neither write is authorized again here: see the moduledoc of
  `AshEnterprise.Accounts.Offboarding` for why, and for what bounds it.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Accounts.{ApiKey, Token, User}
  alias AshEnterprise.Accounts.Offboarding.Actions.Open

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      offboarding = changeset.data

      case Open.leaver_state(offboarding.leaver_id) do
        :reactivated ->
          Ash.Changeset.force_change_attribute(changeset, :leaver_state, :reactivated)

        :inactive ->
          sessions = revoke_tokens(offboarding.leaver_id)
          keys = archive_api_keys(offboarding.leaver_id, context)

          Ash.Changeset.force_change_attributes(changeset, %{
            leaver_state: :inactive,
            sessions_revoked: offboarding.sessions_revoked + sessions,
            api_keys_revoked: offboarding.api_keys_revoked + keys,
            revoked_at: DateTime.utc_now()
          })
      end
    end)
  end

  # The sign-in machinery's own tokens, read and revoked as that machinery.
  @plumbing [
    context: %{private: %{ash_authentication?: true}},
    authorize?: false
  ]

  defp revoke_tokens(user_id) do
    subject = AshAuthentication.user_to_subject(%User{id: user_id})

    live =
      Token
      |> Ash.Query.filter(subject == ^subject and purpose != "revocation" and expires_at > now())
      |> Ash.count!(@plumbing)

    if live > 0 do
      %{status: :success} =
        Ash.bulk_update(
          Token,
          :revoke_all_stored_for_subject,
          %{subject: subject},
          Keyword.merge(@plumbing,
            strategy: [:atomic, :atomic_batches, :stream],
            return_errors?: true,
            stop_on_error?: true
          )
        )
    end

    live
  end

  # Archived (soft-deleted) keys are never read again, so every key read here is live.
  defp archive_api_keys(user_id, context) do
    ApiKey
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&Ash.destroy!(&1, authorize?: false, actor: context.actor))
    |> length()
  end
end
