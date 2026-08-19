defmodule AshEnterprise.Platform.Changes.StampProvenance do
  @moduledoc """
  Fills in the provenance columns every platform resource already had.

  `AshEnterprise.Platform.SystemAttributes` has always declared Dataverse's four
  provenance columns — `created_by_id`, `modified_by_id`,
  `created_on_behalf_by_id`, `modified_on_behalf_by_id` — and until this change
  existed, **nothing ever wrote to any of them.** Every row in the system carried
  four null columns describing who was responsible for it, which is worse than
  not having the columns: a reader sees the shape of an answer and infers there
  is one.

  The central audit log knew, which is why the gap survived. But `created_by_id`
  on the record is not the same artefact as an event in a log: it is what an
  ordinary list view, an export, or a policy can use without joining to the audit
  trail, and it is what survives a retention window that the log does not.

  ## On behalf of

  When the actor is impersonating — see `AshEnterprise.Security.Impersonation` —
  the *subject* goes in `created_by_id` and the *operator* in
  `created_on_behalf_by_id`. That ordering matters and matches Dataverse: the
  record belongs to the customer, and the second column is what tells an auditor
  a support engineer was at the keyboard.

  ## System actors

  A system actor has no id, so it leaves these columns null and its attribution
  stays where it can actually live: `system_actor` in the audit event's metadata.
  "The nightly reconciliation did this" and "we do not know who did this" remain
  distinguishable, which is the whole reason `AshEnterprise.Platform.SystemActor`
  is a named constant rather than a nil.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Security.Impersonation

  @impl true
  def change(changeset, _opts, context) do
    actor_id = actor_id(context.actor)
    operator_id = Impersonation.impersonator_id(context.actor)

    case changeset.action_type do
      :create ->
        changeset
        |> put(:created_by_id, actor_id)
        |> put(:created_on_behalf_by_id, operator_id)

      :update ->
        changeset
        |> put(:modified_by_id, actor_id)
        |> put(:modified_on_behalf_by_id, operator_id)

      _ ->
        changeset
    end
  end

  # Atomic so the change does not force `require_atomic? false` onto every update
  # action on every platform resource. Bulk updates keep working, and the columns
  # are still filled.
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end

  defp actor_id(%AshEnterprise.Platform.SystemActor{}), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil

  defp put(changeset, _attribute, nil), do: changeset

  defp put(changeset, attribute, value) do
    if Ash.Resource.Info.attribute(changeset.resource, attribute) do
      Ash.Changeset.force_change_attribute(changeset, attribute, value)
    else
      changeset
    end
  end
end
