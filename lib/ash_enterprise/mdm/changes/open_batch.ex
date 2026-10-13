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

      require Ash.Query

      mapping =
        AshEnterprise.Mdm.Mapping
        |> Ash.Query.filter(id == ^mapping_id)
        |> Ash.read_one!(tenant: tenant, authorize?: false)

      case mapping do
        %{status: :active, content_hash: hash} when is_binary(hash) ->
          rule_set = active_rule_set(tenant, mapping.target_resource)

          changeset
          |> Ash.Changeset.force_change_attribute(
            :correlation_id,
            AshEnterprise.Platform.Correlation.id()
          )
          |> Ash.Changeset.force_change_attribute(:mapping_content_hash, hash)
          |> maybe_pin_rule_set(rule_set)

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

  defp maybe_pin_rule_set(changeset, nil), do: changeset

  defp maybe_pin_rule_set(changeset, %{id: id, content_hash: hash}) when is_binary(hash) do
    changeset
    |> Ash.Changeset.force_change_attribute(:rule_set_id, id)
    |> Ash.Changeset.force_change_attribute(:rule_set_content_hash, hash)
  end

  defp active_rule_set(tenant, golden_resource) do
    AshEnterprise.Mdm.MatchRuleSet
    |> Ash.Query.filter(golden_resource == ^golden_resource and status == :active)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end
end
