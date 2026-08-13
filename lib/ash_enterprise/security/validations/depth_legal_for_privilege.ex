defmodule AshEnterprise.Security.Validations.DepthLegalForPrivilege do
  @moduledoc """
  Rejects a role grant whose depth the privilege's resource cannot support.

  An `:organization_owned` resource has no owner and no business unit, so a
  `:basic` or `:local` grant on it reaches exactly zero records. That is worse
  than an error, because in an admin UI it *looks* like a deliberate restriction:
  someone will read "Read Currency — User" as "can read their own currencies" and
  file a bug when the list comes back empty.

  The legal set per ownership model lives in
  `AshEnterprise.Security.Privilege.legal_depths/1`, so the seeder, this
  validation and the conformance tests cannot drift apart.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    depth = Ash.Changeset.get_attribute(changeset, :depth)
    privilege_id = Ash.Changeset.get_attribute(changeset, :privilege_id)

    with {:ok, privilege} <- fetch_privilege(privilege_id),
         :ok <- check(privilege, depth) do
      :ok
    else
      {:error, %Ash.Error.Changes.InvalidAttribute{} = error} -> {:error, error}
      {:error, reason} when is_binary(reason) -> invalid(reason)
      # A missing privilege is the foreign key's problem to report, not ours --
      # duplicating it here would produce two errors for one mistake.
      :missing -> :ok
    end
  end

  defp fetch_privilege(nil), do: :missing

  defp fetch_privilege(privilege_id) do
    AshEnterprise.Security.Privilege
    |> Ash.Query.filter(id == ^privilege_id)
    |> Ash.Query.select([:id, :name, :can_be_basic, :can_be_local, :can_be_deep, :can_be_global])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> :missing
      {:ok, privilege} -> {:ok, privilege}
      {:error, error} -> {:error, error}
    end
  end

  defp check(privilege, depth) do
    allowed? =
      case depth do
        :basic -> privilege.can_be_basic
        :local -> privilege.can_be_local
        :deep -> privilege.can_be_deep
        :global -> privilege.can_be_global
        _ -> false
      end

    if allowed? do
      :ok
    else
      {:error,
       """
       #{privilege.name} cannot be granted at the #{depth} depth, because its \
       resource's ownership model does not support it. A grant at this depth \
       would reach no records at all while appearing in the UI as a restriction. \
       Legal depths for this privilege: #{legal(privilege)}.\
       """}
    end
  end

  defp legal(privilege) do
    [
      {:basic, privilege.can_be_basic},
      {:local, privilege.can_be_local},
      {:deep, privilege.can_be_deep},
      {:global, privilege.can_be_global}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map_join(", ", &to_string(elem(&1, 0)))
  end

  defp invalid(message) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :depth,
       message: message
     )}
  end
end
