defmodule AshEnterprise.Bpmn.Subscription.Changes.StampGrantedDefinitions do
  @moduledoc """
  Stamps the definitions a standing grant covers: the ones its publisher saw.

  `granted_definition_ids` is what `AshEnterprise.Bpmn.Subscription.Validations.StandingGrantSteps.definitions/2`
  reads when the version is published, the latest published version of its process and of
  every call activity's child, the same set that validation checked. At every step,
  `AshEnterprise.Process.RecipeAuthority` refuses an instance, or an ancestor of it, whose
  definition is not in the set (`:definition_not_granted`), so a later version under the key
  runs nothing until a person publishes the recipe again (ADR 0069).

  Never from input. A `before_action` hook, so it runs after authorization and inside the
  publish's transaction.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Bpmn.Subscription.Validations.StandingGrantSteps

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      ids =
        changeset
        |> Ash.Changeset.get_attribute(:process_key)
        |> StandingGrantSteps.definitions(changeset.tenant)
        |> Enum.map(& &1.id)

      case ids do
        [] ->
          Ash.Changeset.add_error(changeset,
            field: :process_key,
            message: "a standing grant needs a published process to cover"
          )

        ids ->
          Ash.Changeset.force_change_attribute(changeset, :granted_definition_ids, ids)
      end
    end)
  end
end
