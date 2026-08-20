defmodule AshEnterpriseWeb.A2ui.ProjectedUserUI do
  @moduledoc """
  A2UI surface for the projected users — the same people, over a table this application owns.

  Deliberately the near-twin of `AshEnterpriseWeb.A2ui.LegacyUserUI`, because the comparison is
  the demonstration. That surface reads a compatibility view over a 2010-era Rails schema; this
  one reads `projected_users`, a table created by `mix ash.codegen` with ordinary columns and an
  ordinary unique index. The declaration is the same length and says the same things, and
  nothing in it knows where the rows came from.

  ## What differs, and why each difference is real

    * **`projected_at` instead of nothing.** The projection is not synchronous with the legacy
      write — it happens on commit, through a notification — so there is a lag, and a surface
      that hid it would be claiming a guarantee the design does not make. Putting the timestamp
      on screen makes the lag a number rather than a hope.

    * **`legacy_id` is still here.** Not because this table needs it, but because anyone
      reproducing the demo needs to know which row they just wrote, and because it is the upsert
      key: seeing it lets you check that a second `UPDATE` of the same legacy row updates a row
      here rather than adding one.

    * **`legacy_state` and `lifecycle_status` still sit side by side**, as they do on the legacy
      surface, and the reason is now stronger rather than weaker. There the pair makes a
      five-onto-two collapse visible as a derivation. Here the collapse has already *happened*:
      `lifecycle_status` was reached by running the platform's own declared state-machine
      transition, so the two columns are a legacy fact and a platform fact that agree, and an
      auditor can find the transition that reconciled them.

      (`row_layout`'s `badge` must name one of the table's own fields — `AshA2ui`'s layout
      verifier refuses otherwise, which is how an earlier draft of this very paragraph was
      caught claiming the column had been dropped.)

  ## Sorting

  `legacy_id: :desc`, matching the legacy surface, and for the same two reasons: the legacy
  `created_at` is a bare local-time timestamp written across three server moves, and a new row
  has to land at the top of the page or the update happens where nobody is looking.

  `projected_at` would be a defensible sort too, and is deliberately not the default: it orders
  by when *this application* noticed, which on a backfill is one indistinguishable instant for
  every row.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Accounts.ProjectedUser
    surface_id "projected_users"

    query :default do
      search_fields [:email, :login, :full_name]
      sortable [:legacy_id, :login, :projected_at]
      default_sort legacy_id: :desc
      page_size 25
    end

    component :table do
      fields [
        :legacy_id,
        :full_name,
        :login,
        :email,
        :legacy_state,
        :lifecycle_status,
        :projected_at
      ]

      read_action :read
      query :default

      row_layout do
        title :full_name
        badge :lifecycle_status
        meta [:login, :email, :legacy_state, :projected_at]
        columns 3
      end
    end

    field :legacy_id do
      label "Legacy id"
    end

    field :legacy_state do
      label "Legacy state"
    end

    field :projected_at do
      label "Projected"
    end

    field :lifecycle_status do
      label "Status"
    end
  end
end
