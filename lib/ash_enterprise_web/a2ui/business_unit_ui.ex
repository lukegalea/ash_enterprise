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
      sortable [:name, :depth, :path]

      # Sorting by `path` is what makes the surface a tree rather than a list.
      # Every segment is a fixed-width UUID, so lexicographic path order is
      # exactly depth-first pre-order and each unit lands directly beneath its
      # parent -- which is the ordering `tree_label`'s indentation assumes.
      # Siblings therefore order by id rather than by name; sorting by name
      # instead would separate a parent from its children entirely.
      default_sort path: :asc
      page_size 50
    end

    component :table do
      fields [:tree_label, :breadcrumb, :is_disabled]
      read_action :read
      query :default

      row_layout do
        title :tree_label
        badge :is_disabled
        badge_text true: "Disabled", false: "Active"
        meta [:breadcrumb]
        columns 1
      end
    end

    field :tree_label do
      # The name, indented by depth. A2UI has nowhere to express indentation --
      # no component in any version of the spec carries a padding or spacing
      # property -- but every Text value is rendered as markdown, so the indent
      # travels inside the string. See the calculation on the resource.
      label "Name"
    end

    field :breadcrumb do
      # Replaces `path`, which was a chain of UUIDs: at body size in a
      # proportional font it was the most visually prominent thing on the row,
      # dominating the name, while being a debugging aid nobody reads. Same
      # chain, resolved to names. `path` itself is unchanged -- it is an
      # authorization structure, and this is only its display.
      label "Ancestry"
    end

    component :form do
      fields [:name, :division_name, :cost_center]
      create_action :create
    end
  end
end
