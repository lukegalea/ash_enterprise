defmodule AshEnterpriseWeb.A2ui.TeamUI do
  @moduledoc """
  A2UI surface for teams.

  `team_type` is shown but not editable. Changing an owner team to an access
  team strips inherited roles from every member without touching a single role
  row, which is invisible in an audit of role assignments -- so the resource
  makes it immutable and this surface follows.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Accounts.Team
    surface_id "teams"

    query :default do
      search_fields [:name]
      sortable [:name, :team_type]
      default_sort name: :asc
      page_size 25
    end

    component :table do
      fields [:name, :team_type, :description, :is_default]
      read_action :read
      query :default

      # Without this, rows are flat cell Rows carrying no `weight`, so every
      # column is content-sized: "Sales" and "Enterprise Sales" push everything
      # after them to a different x and nothing lines up down the page. This is
      # the only encoder path that emits weights.
      row_layout do
        title :name
        badge :team_type

        badge_text owner: "Owner",
                   access: "Access",
                   security_group: "Security group",
                   office_group: "Office group"

        meta [:description, :is_default]
        columns 2
      end
    end

    component :form do
      fields [:name, :description, :team_type]
      create_action :create
    end
  end
end
