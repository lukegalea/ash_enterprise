defmodule AshEnterprise.Bpmn.Subscription.Changes.StampAccountablePerson do
  @moduledoc """
  Stamps the person publishing a standing grant as the version's accountable person.

  Read from the actor the call was made with, never from input. A `before_action` hook, so
  it runs after authorization: `publish_granted` is `human_only`, so a system actor, an
  automation principal or an engine-marked call has already been refused as Forbidden, and
  an actor that is still not a person is refused here, never stamped.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Accounts.User

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case context.actor do
        %User{id: id} when is_binary(id) ->
          Ash.Changeset.force_change_attribute(changeset, :accountable_person_id, id)

        _not_a_person ->
          Ash.Changeset.add_error(changeset,
            field: :accountable_person_id,
            message: "a standing grant is published by a person"
          )
      end
    end)
  end
end
