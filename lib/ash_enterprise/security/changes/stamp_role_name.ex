defmodule AshEnterprise.Security.Changes.StampRoleName do
  @moduledoc """
  Puts what the role being assigned is into the assignment's audit metadata: whether it is
  privileged (`privileged`, `AshEnterprise.Security.PrivilegedRoles`) and its name
  (`role_name`), so a recipe can tell a privileged assignment from any other.

  An assignment's audit row carries `role_id`, which is a different id in every tenant, so a
  recipe guard cannot say "a privileged role was assigned" from the row alone, and a guard
  must not query (`AshEnterprise.Audit.EventSource`: the context is a snapshot). Both are
  read here, on the action's own write path, and travel in the event's `metadata`, which
  the event context publishes to guards:

      metadata.privileged = true

  `privileged` is what the role grants, not what it is called: a renamed role is as
  privileged as it was, and a role named "Administrator" that grants nothing is not. The name
  stays in the record for the reviewer. Both are as of the assignment: renaming a role, or
  changing its grants, later does not change what an earlier assignment's row says, which is
  what a record of the assignment should say.

  The lookups run in a `before_action`, after the action's policies admitted the caller, and
  read without authorization in the call's tenant, as `ReturnHeldAssignment` does: this is
  the action's own write path, not a policy check. They override any `role_name` or
  `privileged` a caller put into the context, so the stamp says what was assigned and not
  what a caller claimed. A
  repeat that `ReturnHeldAssignment` turns into a no-op writes no event, so there is nothing
  to stamp.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Security.PrivilegedRoles

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case role_name(changeset) do
        nil ->
          changeset

        name ->
          role_id = Ash.Changeset.get_attribute(changeset, :role_id)
          opts = [authorize?: false, tenant: changeset.tenant]
          stamp(changeset, name, PrivilegedRoles.privileged?(role_id, opts))
      end
    end)
  end

  defp stamp(changeset, name, privileged?) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.merge(%{"role_name" => name, "privileged" => privileged?})

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

  # Context plumbing and reads of the role's name and grants; nothing here reads the clock.
  @impl true
  def temporal_safe?(_opts), do: true
end
