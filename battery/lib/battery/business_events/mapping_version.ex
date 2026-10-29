defmodule Battery.BusinessEvents.MappingVersion do
  @moduledoc """
  The macro-generated MappingVersion on the battery's own base — the
  content-hashed mapping artifact store.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshDiscreteBusinessEvents.Resources, :mapping_version

  postgres do
    table "mapping_versions"
    repo Battery.Repo
  end
end
