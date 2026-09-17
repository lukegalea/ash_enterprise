defmodule AshEnterpriseWeb.A2ui.ProfileUI do
  @moduledoc """
  A2UI surface over tailoring profiles — who tailored what, against which
  catalog. The tailoring operations themselves live on the profile's
  revisions and are a drill-down, not a table column.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.Profile
    surface_id "compliance-profiles"

    query :default do
      sortable [:name]
      page_size 25
    end

    component :table do
      fields [:name, :organization_id, :catalog_id, :oscal_uuid]
      read_action :read
      query :default

      row_layout do
        title :name
        meta [:oscal_uuid]
        columns 1
      end
    end
  end
end
