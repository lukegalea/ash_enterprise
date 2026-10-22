defmodule AshEnterprise.Surfaces.Surface do
  @moduledoc """
  One entry in the surface registry (`AshEnterprise.Surfaces`).

  | Field | Meaning |
  |---|---|
  | `key` | Unique atom; the registry's primary key (`:today`, `:legacy_users`) |
  | `label` | Human name, used in nav, the launcher and page headers |
  | `blurb` | One on-screen sentence (launcher card, page header) |
  | `description` | Model-facing: when the helper should pick this surface. `nil` means the helper may not host it |
  | `group` | `:day`, `:operator`, `:org`, `:processes`, `:data`, `:mdm`, `:compliance` or `:legacy` |
  | `order` | Position within its group |
  | `icon` | Heroicon name for the launcher card |
  | `path` | The web route (`/app/...`) |
  | `live` / `live_action` | The LiveView (and action) routed at `path`; how the web door finds the entry |
  | `ui` | The `AshA2ui` UI module the page renders, or `nil` for a hand-written page |
  | `resource` | The Ash resource the surface is about |
  | `context` | The A2UI context on `ui` that selects one `resource` record for detail, or `nil` |
  | `record_match` | Attribute values a record must have to be *this* surface's, when several surfaces show the same resource (Inbox and Slack over `Conversation`); `[]` matches any |
  | `door` | `:signed_in`, `:operator`, `:compliance`, `:lineage` or `:audit`; checked by `AshEnterprise.Surfaces.Doors` on web and ACP |
  | `acp` | `nil` or the ACP command spec, see below |

  ## `acp`

      %{
        command: "calendar",               # the prompt word that opens it
        aliases: ["agenda"],               # other words that do
        params: [window: {:one_of, ~w(today tomorrow week upcoming)}],
        action: {Console, :agenda},        # what it runs; `Ash.can?` prunes the palette on it
        description: "Agenda for a window",
        palette?: true,                    # listed in `available_commands_update`
        ui: nil,                           # an ACP-only UI override (erasure: no shred)
        verbs: [%{command: "approve", action: {HumanTask, :approve}, hint: "N | brief",
                  description: "..."}]
      }

  Surfaces without a bespoke action open through `Console.open` (`open <command>`).
  """

  @enforce_keys [:key, :label, :blurb, :group, :order, :path, :live]
  defstruct [
    :key,
    :label,
    :blurb,
    :description,
    :group,
    :order,
    :path,
    :live,
    :live_action,
    :ui,
    :resource,
    :context,
    :acp,
    record_match: [],
    icon: "hero-squares-2x2",
    door: :signed_in
  ]

  @type door :: :signed_in | :operator | :compliance | :lineage | :audit
  @type group ::
          :day | :operator | :org | :processes | :data | :mdm | :compliance | :legacy

  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          blurb: String.t(),
          description: String.t() | nil,
          group: group(),
          order: non_neg_integer(),
          icon: String.t(),
          path: String.t(),
          live: module(),
          live_action: atom() | nil,
          ui: module() | nil,
          resource: module() | nil,
          context: atom() | nil,
          record_match: keyword(),
          door: door(),
          acp: map() | nil
        }
end
