defmodule AshEnterpriseWeb.A2ui.Surfaces do
  @moduledoc """
  The catalogue of declared A2UI surfaces, and the one place that knows how to
  host one.

  Three callers need this and each needed something slightly different, which is
  why it exists rather than each of them keeping its own list:

    * `AshEnterpriseWeb.A2uiLive` mounts one surface per route.
    * `AshEnterpriseWeb.AgentLive` picks one at runtime, because a person asked
      for it in a sentence.
    * The helper agent needs to be *told* what exists, in words, so a model can
      choose between them.

  ## Topics are derived, never spelled

  `AshA2ui.LiveRenderer` cannot introspect a resource's publications, so the
  topics a surface subscribes to have to come from somewhere. Writing them out
  next to the `pub_sub` block would be two independent spellings of the same
  strings, and a typo in either produces a page that silently never updates,
  with nothing logged anywhere.

  So `topics/1` reads them straight off the resource's publications. There is one
  declaration — the `pub_sub` block — and the subscription is computed from it.
  A surface whose resource publishes nothing gets `[]` and is simply not live,
  which is the correct answer rather than a special case.
  """

  alias AshEnterprise.Legacy
  alias AshEnterpriseWeb.A2ui

  @surfaces [
    %{
      name: "users",
      label: "Users",
      ui: A2ui.UserUI,
      path: "/app/users",
      blurb: "People with accounts in this application.",
      description: "People with accounts in this application, with their status and sign-up date."
    },
    %{
      name: "teams",
      label: "Teams",
      ui: A2ui.TeamUI,
      path: "/app/teams",
      blurb: "Teams, which own records alongside users.",
      description: "Teams, which own records alongside users in the polymorphic ownership model."
    },
    %{
      name: "roles",
      label: "Roles",
      ui: A2ui.RoleUI,
      path: "/app/roles",
      blurb: "Named bundles of privileges a user can hold.",
      description: "Security roles, which are the named bundles of privileges a user can hold."
    },
    %{
      name: "business_units",
      label: "Business units",
      ui: A2ui.BusinessUnitUI,
      path: "/app/business-units",
      blurb: "The hierarchy that authorization depth expands over.",
      description: "The business-unit hierarchy that authorization depth expands over."
    },
    %{
      name: "legacy_users",
      label: "Legacy users",
      ui: A2ui.LegacyUserUI,
      path: "/app/legacy-users",
      blurb: "The old system's people, read live through a compatibility view.",
      description:
        "People in the OLD system — a 2010-era Rails schema, read through a compatibility " <>
          "view. Ask for these when the request mentions the legacy system, the old " <>
          "application, or migrated data. This surface updates itself when the legacy " <>
          "application writes."
    }
  ]

  @doc "Every declared surface, in menu order."
  @spec all() :: [map()]
  def all, do: @surfaces

  @doc "The surface with this name, or `nil`."
  @spec fetch(String.t() | nil) :: map() | nil
  def fetch(nil), do: nil

  def fetch(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")

    Enum.find(@surfaces, &(&1.name == normalized))
  end

  @doc "The surface names a model may choose between."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@surfaces, & &1.name)

  @doc """
  The catalogue as prose, for a prompt.

  Uses `:description`, not `:blurb`. They are different audiences and the
  difference showed the first time a surface was rendered: the description tells
  a *model* when to pick this surface ("ask for these when the request mentions
  the legacy system"), and putting that on screen reads as the application
  talking to itself in front of the user.

  Built from the same list the application renders from, so a surface added
  above becomes available to the helper agent without anybody remembering to
  describe it a second time.
  """
  @spec catalogue() :: String.t()
  def catalogue do
    Enum.map_join(@surfaces, "\n", fn surface ->
      "  - #{surface.name}: #{surface.description}"
    end)
  end

  @doc """
  The Phoenix.PubSub topics a surface should subscribe to, read off its
  resource's `Ash.Notifier.PubSub` publications.

  Returns `[]` for a resource with no publications — that surface is not live,
  and saying so by returning nothing is better than pretending otherwise.
  """
  @spec topics(map() | module()) :: [String.t()]
  def topics(%{ui: ui}), do: topics(ui)

  def topics(ui_module) do
    resource = AshA2ui.Info.resource!(ui_module)

    if function_exported?(resource, :spark_dsl_config, 0) and
         Ash.Notifier.PubSub in Ash.Resource.Info.notifiers(resource) do
      prefix = Ash.Notifier.PubSub.Info.prefix(resource)

      resource
      |> Ash.Notifier.PubSub.Info.publications()
      |> Enum.flat_map(fn publication ->
        publication.topic
        |> List.wrap()
        |> Enum.map(&topic_string(prefix, &1))
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  # A topic template is a list of segments; the ones here are plain strings, but
  # a template carrying an interpolated field (`[:id, "updated"]`) cannot be
  # subscribed to without knowing the value, so it is skipped rather than
  # subscribed to under a wrong name.
  defp topic_string(prefix, segment) when is_binary(segment) do
    if prefix, do: "#{prefix}:#{segment}", else: segment
  end

  defp topic_string(_prefix, _segment), do: nil

  @doc """
  Whether a surface refreshes itself when its underlying rows change.

  Used to decide whether to promise live updates in the UI. Promising them for a
  surface that cannot deliver is worse than not mentioning them.
  """
  @spec live?(map() | module()) :: boolean()
  def live?(surface), do: topics(surface) != []

  @doc """
  The `AshA2ui.LiveRenderer` config for hosting `surface` at runtime.

  `AshEnterpriseWeb.AgentLive` does not know at compile time which surface it
  will show, so it cannot `use AshA2ui.LiveRenderer` — it builds a config when
  somebody asks for one and drives the renderer's public functions with it.
  """
  @spec renderer_config(map(), keyword()) :: map()
  def renderer_config(surface, opts) do
    AshA2ui.LiveRenderer.build_config(
      ui: surface.ui,
      actor_fn: fn _socket -> opts[:actor] end,
      tenant_fn: fn _socket -> opts[:tenant] end,
      pubsub: pubsub_opts(surface)
    )
  end

  defp pubsub_opts(surface) do
    case topics(surface) do
      [] -> nil
      topics -> [module: AshEnterprise.PubSub, topics: topics]
    end
  end

  @doc """
  The resources the helper agent may compose an ad-hoc surface over.

  An allowlist, and host configuration rather than client input: it gates both
  the surface's resource and every context resource, so a model cannot compose
  its way to a table this application never meant to publish. Kept to what an
  operator may reasonably see end to end.
  """
  @spec dynamic_allowlist() :: %{String.t() => module()}
  def dynamic_allowlist do
    # Named explicitly rather than by module, because `AshEnterprise.Accounts.User`
    # and `AshEnterprise.Legacy.User` collide on their short name -- and that
    # collision is the point of the whole strangler exercise, so it is not going
    # away. Naming them is also what a model sees, and "user" versus
    # "legacy_user" is a distinction it can act on where "User" twice is not.
    AshA2ui.Dynamic.allowlist(%{
      "user" => AshEnterprise.Accounts.User,
      "team" => AshEnterprise.Accounts.Team,
      "business_unit" => AshEnterprise.Accounts.BusinessUnit,
      "role" => AshEnterprise.Security.Role,
      "legacy_user" => Legacy.User
    })
  end
end
