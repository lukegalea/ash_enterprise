defmodule AshEnterprise.Security.Changes.ReturnHeldAssignment do
  @moduledoc """
  Assigning a role someone already holds, in the same scope, returns the assignment in force
  and writes nothing: no row, no audit event.

  `assign` and `assign_governed` upsert on `unique_assignment`, which keeps a repeat to one
  row. But the audit wrapper records every create that reaches the data layer, the upsert
  included, so a repeat used to write a second `:assign` event indistinguishable from the
  first (the same snapshot, the same version), and a recipe watching role assignments
  started a second review for an assignment nobody changed. An agent or a directory sync
  re-asserting a role does exactly that.

  So the in-force assignment is looked up before the create runs and, when it already says
  what the call says, becomes the action's result (`Ash.Changeset.set_result/2`), which skips
  the data layer and with it the audit event. A call that changes something the assignment
  carries (a different `valid_until`) is a change, and still runs the upsert and is recorded.

  The lookup runs in a `before_action`, after the action's policies admitted the caller, so
  a caller learns nothing they could not have learnt by assigning. It reads without
  authorization in the call's tenant, as `DefaultScopingBusinessUnit` reads the user: this is
  the action's own write path, not a policy check. Two concurrent first assignments can both
  miss the lookup; the upsert still keeps them to one row, and the second records an event.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case held(changeset) do
        nil -> changeset
        assignment -> held_result(changeset, assignment)
      end
    end)
  end

  defp held_result(changeset, assignment) do
    if same_terms?(changeset, assignment) do
      Ash.Changeset.set_result(changeset, {:ok, assignment})
    else
      changeset
    end
  end

  # The only term an assignment carries beyond its key is when it ends.
  defp same_terms?(changeset, assignment) do
    not Ash.Changeset.changing_attribute?(changeset, :valid_until) or
      same_instant?(Ash.Changeset.get_attribute(changeset, :valid_until), assignment.valid_until)
  end

  defp same_instant?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_instant?(a, b), do: a == b

  defp held(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    role_id = Ash.Changeset.get_attribute(changeset, :role_id)
    unit_id = Ash.Changeset.get_attribute(changeset, :scoping_business_unit_id)

    if Enum.any?([user_id, role_id, unit_id], &is_nil/1) do
      nil
    else
      changeset.resource
      |> Ash.Query.filter(
        user_id == ^user_id and role_id == ^role_id and scoping_business_unit_id == ^unit_id
      )
      |> Ash.read_one!(authorize?: false, tenant: changeset.tenant)
    end
  end
end
