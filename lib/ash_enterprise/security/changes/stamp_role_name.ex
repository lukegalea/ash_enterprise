defmodule AshEnterprise.Security.Changes.StampRoleName do
  @moduledoc """
  Puts the name of the role being assigned into the assignment's audit metadata
  (`role_name`), so a recipe can tell an Administrator assignment from any other.

  An assignment's audit row carries `role_id`, which is a different id in every tenant, so a
  recipe guard cannot say "an Administrator was assigned" from the row alone, and a guard
  must not query (`AshEnterprise.Audit.EventSource`: the context is a snapshot). The name is
  read here, on the action's own write path, and travels in the event's `metadata`, which
  the event context publishes to guards as `metadata.role_name`:

      metadata.role_name = "Administrator" or metadata.role_name = "Platform Operator"

  It is the name at the moment of the assignment. Renaming a role later does not change what
  an earlier assignment's row says, which is what a record of the assignment should say.

  The lookup runs in a `before_action`, after the action's policies admitted the caller, and
  reads without authorization in the call's tenant, as `ReturnHeldAssignment` does: this is
  the action's own write path, not a policy check. It overrides any `role_name` a caller put
  into the context, so the stamp says what was assigned and not what a caller claimed. A
  repeat that `ReturnHeldAssignment` turns into a no-op writes no event, so there is nothing
  to stamp.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case role_name(changeset) do
        nil -> changeset
        name -> stamp(changeset, name)
      end
    end)
  end

  defp stamp(changeset, name) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.put("role_name", name)

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
  end

  defp role_name(changeset) do
    case Ash.Changeset.get_attribute(changeset, :role_id) do
      nil ->
        nil

      role_id ->
        AshEnterprise.Security.Role
        |> Ash.Query.filter(id == ^role_id)
        |> Ash.Query.select([:name])
        |> Ash.read_one!(authorize?: false, tenant: changeset.tenant)
        |> case do
          %{name: name} -> name
          nil -> nil
        end
    end
  end

  # Context plumbing and one read of the role's name; nothing here reads the clock.
  @impl true
  def temporal_safe?(_opts), do: true
end
