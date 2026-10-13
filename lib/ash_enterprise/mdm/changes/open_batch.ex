defmodule AshEnterprise.Mdm.Changes.OpenBatch do
  @moduledoc """
  Mints the correlation id, pins the mapping's content hash, and refuses
  to open against anything but the ACTIVE mapping version for the tuple —
  a batch is defined by the live mapping, and `:open` is the only place
  that binding is made.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      mapping_id = Ash.Changeset.get_attribute(changeset, :mapping_id)
      tenant = changeset.tenant

      mapping =
        AshEnterprise.Mdm.Mapping
        |> Ash.Query.filter(id == ^mapping_id)
        |> Ash.read_one!(tenant: tenant, authorize?: false)

      case mapping do
        %{status: :active, content_hash: hash} when is_binary(hash) ->
          changeset
          |> Ash.Changeset.force_change_attribute(
            :correlation_id,
            AshEnterprise.Platform.Correlation.id()
          )
          |> Ash.Changeset.force_change_attribute(:mapping_content_hash, hash)

        _ ->
          Ash.Changeset.add_error(
            changeset,
            field: :mapping_id,
            message:
              "must reference the ACTIVE version of a mapping, got status: #{mapping && mapping.status}"
          )
      end
    end)
  end
end
