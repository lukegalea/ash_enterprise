defmodule AshEnterprise.Documents.PaperClause.Changes.Admit do
  @moduledoc """
  Stamps `admitted_by_id` on `admit` (the state machine moves `status`) from
  the acting person, the way `StampProvenance` stamps `created_by_id` —
  from the action's context actor, never from a client-supplied value. A system
  actor leaves `admitted_by_id` null and its attribution stays in the audit
  event's metadata, the same bound as everywhere else on the platform.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Platform.SystemActor

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.force_change_attribute(changeset, :admitted_by_id, actor_id(context.actor))
  end

  defp actor_id(%SystemActor{}), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil
end
