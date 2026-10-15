defmodule AshEnterprise.Integration.Changes.OwnedByActor do
  @moduledoc """
  Makes the acting human the owner of the record being created.

  Ownership is never an input here: a linked account belongs to whoever linked
  it, so nobody can create a link that another user would then spend. A
  non-human actor (no `user_id` in its `ActorContext`) cannot own one and is
  refused.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Security.ActorContext

  @impl true
  def change(changeset, _opts, context) do
    actor_context = ActorContext.for_actor(context.actor)

    case actor_context.user_id do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: :owner_id,
          message: "a linked account must be owned by a human actor"
        )

      user_id ->
        changeset
        |> Ash.Changeset.force_change_attribute(:owner_id, user_id)
        |> Ash.Changeset.force_change_attribute(:owner_type, :user)
        |> Ash.Changeset.force_change_attribute(:owning_user_id, user_id)
        |> Ash.Changeset.force_change_attribute(
          :owning_business_unit_id,
          actor_context.business_unit_id
        )
    end
  end
end
