defmodule AshEnterpriseWeb.A2ui.PolicyBundleUI do
  @moduledoc """
  A2UI surface over compiled policy bundles — the lifecycle view: which
  bundle is active for which tenant, what hash it carries, when it went live.

  The lifecycle transitions (compile/activate/retire) are deliberate
  non-features here: bundle changes flow through the reviewed compile path,
  not through a table row edit.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshCompliance.Resources.PolicyBundle
    surface_id "compliance-bundles"

    query :default do
      sortable [:organization_id, :status]
      page_size 25
    end

    component :table do
      fields [:organization_id, :status, :content_hash, :manifest_revision, :active_at]
      read_action :read
      query :default

      row_layout do
        title :organization_id
        badge :status
        meta [:content_hash]
        columns 1
      end
    end
  end
end
