defmodule AshEnterprise.Security.Changes.StampGrantRevival do
  @moduledoc """
  Records on a grant's `set_valid_until` audit event whether the write brought an ended
  grant back into force, and whether what it brought back is privileged, so the
  `security_alerts` pack can review it as it reviews an assignment.

  A grant whose `valid_until` has passed grants nothing (`AshEnterprise.Security.ActorContext`
  and `AshEnterprise.Security.PrivilegedRoles.holder_ids/2` skip it), and the row stays.
  Clearing that end, or moving it past now, hands the role back to its holder, or to every
  member of the team that holds it, without a create: the write the pack's assignment
  recipes match never happens. So this stamps, on `UserRole :set_valid_until` and
  `TeamRole :set_valid_until`:

    * `revived`: `true` when the grant was not in force before the write (an end at or
      before now) and is after it (no end, or one later than now), else `false`;
    * `privileged`: `true` when it revived and the role is privileged
      (`AshEnterprise.Security.PrivilegedRoles`, by what the role grants), else `false`;
    * `role_name`: the role's name, for the reviewer, when it revived.

  Moving the end of a grant that is still in force hands nothing back: `revived` is
  `false`. That is an extension, which the `soc2_cc6_3` pack reviews for a person's grant
  (`AshEnterprise.Security.Changes.StampValidUntilExtension`).

  A guard must not query, so this is decided here, in a `before_action`, where the stored
  end and the new one are both known, and read without authorization in the call's tenant
  after the action's policies admitted the caller, as `StampRoleName` reads. It overrides
  anything a caller put in the context under these keys.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Security.{PrivilegedRoles, Role}

  @keys ["revived", "privileged", "role_name"]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      before = Map.get(changeset.data, :valid_until)
      after_change = Ash.Changeset.get_attribute(changeset, :valid_until)

      stamp(changeset, stamped(changeset, revived?(before, after_change, DateTime.utc_now())))
    end)
  end

  @doc """
  Whether moving a grant's end from `before` to `after_change` brings it back into force at
  `now`: it was not in force before and is after.
  """
  @spec revived?(DateTime.t() | nil, DateTime.t() | nil, DateTime.t()) :: boolean()
  def revived?(before, after_change, now),
    do: not in_force?(before, now) and in_force?(after_change, now)

  defp in_force?(nil, _now), do: true
  defp in_force?(%DateTime{} = valid_until, now), do: DateTime.compare(valid_until, now) == :gt

  defp stamped(_changeset, false), do: %{"revived" => false, "privileged" => false}

  defp stamped(changeset, true) do
    role_id = Map.get(changeset.data, :role_id)
    opts = [authorize?: false, tenant: changeset.tenant]

    %{
      "revived" => true,
      "privileged" => PrivilegedRoles.privileged?(role_id, opts),
      "role_name" => role_name(role_id, opts)
    }
  end

  defp role_name(role_id, opts) do
    Role
    |> Ash.Query.filter(id == ^role_id)
    |> Ash.Query.select([:name])
    |> Ash.read_one!(opts)
    |> case do
      %Role{name: name} -> name
      nil -> nil
    end
  end

  defp stamp(changeset, stamped) do
    metadata =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.drop(@keys)
      |> Map.merge(stamped)

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
  end
end
