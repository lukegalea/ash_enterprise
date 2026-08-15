defmodule AshEnterpriseWeb.A2ui.BusinessUnitUI do
  @moduledoc """
  A2UI surface for the business-unit hierarchy.

  `path` and `depth` are surfaced read-only. They are platform-maintained
  (`MaintainBusinessUnitPath`) and showing them is genuinely useful when
  debugging why a `:deep` grant reaches what it reaches — the materialized path
  *is* the explanation.

  Reparenting is not offered here. It rewrites the path of an entire subtree and
  silently changes what every `:deep` grant scoped above it can see, which is a
  deliberate administrative act rather than an inline table edit.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Accounts.BusinessUnit
    surface_id "business_units"

    query :default do
      search_fields [:name]
      sortable [:name, :depth]
      default_sort depth: :asc
      page_size 50
    end

    component :table do
      fields [:name, :depth, :path, :is_disabled]
      read_action :read
      query :default

      row_layout do
        title :name
        badge :is_disabled
        badge_text true: "Disabled", false: "Active"
        meta [:depth, :path]
        columns 2
      end
    end

    field :path do
      # The materialized path is a chain of UUIDs. At body size in a
      # proportional font it was the most visually prominent thing on every
      # row, dominating the name -- while being a debugging aid rather than
      # something anyone reads. Keep the column, shrink its claim on attention.
      label "Ancestry"
    end

    component :form do
      fields [:name, :division_name, :cost_center]
      create_action :create
    end
  end
end
