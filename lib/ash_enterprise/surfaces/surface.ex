defmodule AshEnterprise.Surfaces.Surface do
  @moduledoc """
  One entry in the surface registry (`AshEnterprise.Surfaces`).

  | Field | Meaning |
  |---|---|
  | `key` | Unique atom; the registry's primary key (`:today`, `:legacy_users`) |
  | `label` | Human name, used in nav, the launcher and page headers |
  | `blurb` | One on-screen sentence (launcher card, page header) |
  | `description` | Model-facing: when the helper should pick this surface. `nil` means the helper may not host it |
  | `group` | `:day`, `:operator`, `:org`, `:processes`, `:data`, `:mdm`, `:compliance`, `:judgments`, `:credentialing` or `:legacy` |
  | `order` | Position within its group |
  | `icon` | Heroicon name for the launcher card |
  | `path` | The web route (`/app/...`) |
  | `live` / `live_action` | The LiveView (and action) routed at `path`; how the web door finds the entry. Left out when the page is generated (see `renderer`) |
  | `ui` | The `AshA2ui` UI module the page renders, or `nil` for a hand-written page |
  | `renderer` | `:generated`, `:specialist` or `nil`, see below |
  | `resource` | The Ash resource the surface is about |
  | `context` | The A2UI context on `ui` that selects one `resource` record for detail, or `nil` |
  | `record_match` | Attribute values a record must have to be *this* surface's, when several surfaces show the same resource (Inbox and Slack over `Conversation`); `[]` matches any |
  | `door` | `:signed_in`, `:operator`, `:compliance`, `:lineage` or `:audit`; checked by `AshEnterprise.Surfaces.Doors` on web and ACP |
  | `audience` | Who the surface is for, one or more of `:member` (anyone signed in, about their own day), `:reviewer` (decides or checks what others did), `:builder` (shapes processes, rules and mappings) and `:operator` (runs the platform). The launcher's views filter by it. Not a door: it never refuses anybody |
  | `searchable` | Attributes of `resource` that identify one record to a person, a business reference such as a licence number, or `:id` for a run id. `AshEnterprise.Surfaces.Search` looks a typed value up in them; `[]` keeps the surface out of search. Needs a `context`, since a hit opens in detail |
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

  ## `renderer`

    * `:generated`: the entry names a `ui` and no `live`. The registry names
      the LiveView (`AshEnterpriseWeb.SurfaceLive.<Key>`),
      `AshEnterpriseWeb.SurfaceLive` defines it as a plain
      `AshA2ui.LiveRenderer` over `ui`, and the router routes it at `path`.
      Never declared by hand.
    * `:specialist`: a hand-written `AshA2ui.LiveRenderer` that adds live
      behaviour the UI module cannot declare (a refresh banner, reports run on
      arrival, a diagram, an `?as_of=` banner). Declared, so a reviewer sees
      each one; the renderer test refuses any hand-written renderer that is
      not.
    * `nil`: a hand-written LiveView that is not a renderer (a designer, a
      wizard, the tour).
  """

  @enforce_keys [:key, :label, :blurb, :group, :order, :path]
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
    :renderer,
    record_match: [],
    audience: [],
    searchable: [],
    icon: "hero-squares-2x2",
    door: :signed_in
  ]

  @type renderer :: :generated | :specialist | nil
  @type audience :: :member | :reviewer | :builder | :operator
  @type door :: :signed_in | :operator | :compliance | :lineage | :audit
  @type group ::
          :day
          | :operator
          | :org
          | :processes
          | :data
          | :mdm
          | :compliance
          | :judgments
          | :credentialing
          | :legacy

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
          audience: [audience(), ...],
          searchable: [atom()],
          acp: map() | nil,
          renderer: renderer()
        }
end
