defmodule AshEnterprise.Bpmn.Subscription.Changes.WriteStartGrant do
  @moduledoc """
  Writes the accountable person's start grant for the version being published as a standing
  grant, in the same transaction as the publish.

  The grant is an `AshEnterprise.Security.AgentStartGrant` keyed
  `AshEnterprise.Bpmn.Subscription.Authority.grant_key/1` (`recipe:<key>:<version>`), held by
  the person stamped as accountable, and valid for
  `AshEnterprise.Bpmn.Subscription.Authority.grant_review_days/0` days. One per version, so a
  later version never inherits it, and revoking it (or letting it lapse) stops this version's
  steps at their next claim.

  Written without authorization, as part of this action: granting a start is `human_only`,
  and `publish_granted` is that person's own act, already authorized as a person's. The grant
  names only them, so it lets no one else ask for anything.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Security.AgentStartGrant

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, subscription ->
      valid_until = DateTime.add(DateTime.utc_now(), Authority.grant_review_days(), :day)

      %{
        agent_key: Authority.grant_key(subscription),
        principal_id: subscription.accountable_person_id,
        principal_type: :user,
        valid_until: valid_until
      }
      |> AgentStartGrant.grant(
        actor: context.actor,
        tenant: subscription.organization_id,
        authorize?: false
      )
      |> case do
        {:ok, _grant} -> {:ok, subscription}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
