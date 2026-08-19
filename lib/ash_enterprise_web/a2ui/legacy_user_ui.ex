defmodule AshEnterpriseWeb.A2ui.LegacyUserUI do
  @moduledoc """
  A2UI surface for the legacy read model.

  There is nothing here that says "legacy" except the resource it points at, and
  that is the whole demonstration. `AshEnterprise.Legacy.User` reads a
  compatibility view over a 2010-era Rails schema, and this surface is declared
  the same way as the one over `AshEnterprise.Accounts.User` — same DSL, same
  server-enforced query allowlist, same policies applied to the same actor. The
  derivation claim in `docs/manifesto/` has so far only been tested against data
  designed to be derived; this is it meeting data that was not.

  ## Fields, and what they are each doing there

    * `full_name` is a projection the legacy schema cannot write back
      (`'de la Cruz'` splits wrong), so it is read-only in the mapping.
    * `email` is deliberately not unique here. Two seeded rows differ only by
      case, and the legacy index is neither unique nor case-insensitive — a data
      quality defect this surface *shows you* rather than one the read model can
      pretend away.
    * `legacy_state` and `lifecycle_status` sit side by side on purpose. Five
      legacy states collapse onto two platform statuses, and putting both on
      screen is what makes the collapse visible instead of a silent
      reinterpretation.
    * `legacy_id` is the integer primary key the modern uuid was derived from.
      Anyone reproducing the live-update demo needs it to know which row to
      `UPDATE`.

  ## No sorting on `created_on`

  `created_at` in the legacy schema is a bare `timestamp`, written in the server's
  local time, and the app was moved between hosts twice. Sorting by it would
  present three different time zones as a single ordering and look authoritative
  doing it. `legacy_id` is monotonic and honest, so that is what this sorts by
  until the expand step resolves the zones.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Legacy.User
    surface_id "legacy_users"

    query :default do
      search_fields [:email, :login, :full_name]
      sortable [:legacy_id, :login]
      default_sort legacy_id: :asc
      page_size 25
    end

    component :table do
      fields [:legacy_id, :full_name, :login, :email, :legacy_state, :lifecycle_status]
      read_action :read
      query :default

      row_layout do
        title :full_name
        badge :lifecycle_status
        meta [:login, :email, :legacy_state, :legacy_id]
        columns 1
      end
    end

    field :legacy_id do
      label "Legacy id"
    end

    field :legacy_state do
      label "Legacy state"
    end

    field :lifecycle_status do
      label "Status"
    end
  end
end
