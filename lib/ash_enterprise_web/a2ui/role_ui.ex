defmodule AshEnterpriseWeb.A2ui.RoleUI do
  @moduledoc """
  A2UI surface for security roles.

  Read-and-create only. Editing a role's *grants* deliberately happens through
  `AshEnterprise.Security.RolePrivilege`, not here: a grant is a
  `(privilege, depth)` pair whose legality depends on the target resource's
  ownership model, and a generic form would happily submit combinations that
  `DepthLegalForPrivilege` rejects. Surfacing that as a validation error after
  the fact is worse than not offering the control.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Security.Role
    surface_id "roles"

    query :default do
      search_fields [:name]
      sortable [:name, :created_on]
      default_sort name: :asc
      page_size 25
    end

    component :table do
      fields [:name, :description, :is_inherited]
      read_action :read
      query :default
    end

    component :form do
      fields [:name, :description, :is_inherited]
      create_action :create
    end
  end
end
