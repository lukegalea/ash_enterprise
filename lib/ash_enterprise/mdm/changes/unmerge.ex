# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEnterprise.Mdm.Changes.Unmerge do
  @moduledoc """
  The merge correction (ADR 0054): restores exactly what the merge took —
  the prior email and the identities that moved to the survivor — using
  the provenance the merge recorded on this record.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # The restore is ONE write: provenance rides on the record, so the
    # email goes back in this same changeset — no second update, whose
    # event replay would resurrect the merged flag. The identities repoint
    # after the row commits (their history shows merged -> restored).
    provenance = changeset.data.merge_provenance || %{}

    case provenance["prior_email"] do
      email when is_binary(email) and email != "" ->
        Ash.Changeset.force_change_attribute(changeset, :email, email)

      _ ->
        changeset
    end
    |> Ash.Changeset.after_action(fn changeset, result ->
      tenant = changeset.tenant

      for id <- provenance["moved_identity_ids"] || [] do
        case Ash.get(AshEnterprise.Mdm.SourceIdentity, id, tenant: tenant, authorize?: false) do
          {:ok, identity} ->
            identity
            |> Ash.Changeset.for_update(
              :repoint,
              %{golden_resource: "AshEnterprise.Canonical.Person", golden_id: result.id},
              tenant: tenant,
              authorize?: false
            )
            |> Ash.update!(tenant: tenant, authorize?: false)

          _ ->
            :ok
        end
      end

      # Return the committed state so callers (and the test) see the
      # restored record, not a stale struct.
      {:ok,
       Ash.get!(AshEnterprise.Canonical.Person, result.id, tenant: tenant, authorize?: false)}
    end)
  end
end
