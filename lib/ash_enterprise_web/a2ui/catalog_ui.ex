defmodule AshEnterpriseWeb.A2ui.CatalogUI do
  @moduledoc """
  A2UI surface over compliance catalogs — the top of the control plane:
  which catalogs exist, for whom, and which OSCAL document they came from.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.Catalog
    surface_id "compliance-catalogs"

    query :default do
      sortable [:name]
      page_size 25
    end

    context :catalog do
      resource AshCompliance.Resources.Catalog
      picker false
    end

    component :table do
      fields [:name, :organization_id, :oscal_uuid, :description]
      read_action :read
      query :default
      select_context :catalog

      row_layout do
        title :name
        meta [:oscal_uuid]
        columns 1
      end
    end

    component :detail, :catalog_detail do
      context :catalog
      fields [:name, :oscal_uuid, :description]
    end
  end
end
