defmodule Battery.Mdm.Mapping do
  @moduledoc """
  The macro-generated MDM Mapping on the battery's own base. The macro
  supplies attributes, actions and the one-active partial unique index.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshMdm.Resources, {:mapping, repo: Battery.Repo, table: "mdm_mappings"}

end
