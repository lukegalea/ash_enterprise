# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.Mdm.Changes.Unmerge do
  @moduledoc """
  The merge correction (ADR 0054): restores exactly what the merge took —
  the prior email and the identities that moved to the survivor — using
  the provenance the merge recorded on this record, then refolds both sides
  now the chain no longer joins them.

  A merge recorded before attribute assertions has no statements to refold
  from, so those keep their columns as the restore leaves them.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.Refold

  @impl true
  def change(changeset, _opts, _context) do
    # The loser's restore is ONE write: provenance rides on the record, so the
    # email goes back in this same changeset — no second update, whose event
    # replay would resurrect the merged flag. The survivor's release is a
    # separate write and comes first: while the survivor holds the address,
    # restoring it here violates unique_email. The identities repoint after
    # the row commits (their history shows merged -> restored).
    provenance = changeset.data.merge_provenance || %{}

    case provenance["prior_email"] do
      email when is_binary(email) and email != "" ->
        Ash.Changeset.force_change_attribute(changeset, :email, email)

      _ ->
        changeset
    end
    |> Ash.Changeset.before_action(&release_from_survivor(&1, provenance["prior_email"]))
    |> Ash.Changeset.after_action(fn changeset, result ->
      tenant = changeset.tenant

      for id <- provenance["moved_identity_ids"] || [] do
        repoint(id, result.id, tenant)
      end

      # The meetings, messages and conversations the merge moved come back.
      AshEnterprise.Mdm.PersonJoins.restore!(tenant, provenance["joins"], result.id)

      if provenance["assertions_folded"] == true do
        # Held values stay off: the survivor's column still holds what it
        # inherited, which is exactly what this refold takes away.
        Refold.refold!(tenant, provenance["survivor_id"], materialize_held: false)
        Refold.refold!(tenant, result.id, materialize_held: false)
      end

      # Return the committed state so callers (and the test) see the
      # restored record, not a stale struct.
      {:ok, Ash.get!(Person, result.id, tenant: tenant, authorize?: false)}
    end)
  end

  defp release_from_survivor(changeset, email) when is_binary(email) and email != "" do
    tenant = changeset.tenant
    survivor_id = changeset.data.master_id

    Refold.lock!(tenant, [changeset.data.id, survivor_id])
    survivor = Ash.get!(Person, survivor_id, tenant: tenant, authorize?: false)

    if survivor.email && String.downcase(to_string(survivor.email)) == String.downcase(email) do
      survivor
      |> Ash.Changeset.for_update(:mdm_survivor_update, %{email: nil},
        tenant: tenant,
        authorize?: false
      )
      |> Ash.update!(tenant: tenant, authorize?: false)
    end

    changeset
  end

  defp release_from_survivor(changeset, _no_email), do: changeset

  defp repoint(identity_id, golden_id, tenant) do
    case Ash.get(AshEnterprise.Mdm.SourceIdentity, identity_id, tenant: tenant, authorize?: false) do
      {:ok, identity} ->
        identity
        |> Ash.Changeset.for_update(
          :repoint,
          %{golden_resource: "AshEnterprise.Canonical.Person", golden_id: golden_id},
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update!(tenant: tenant, authorize?: false)

      _ ->
        :ok
    end
  end
end
