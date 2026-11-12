defmodule AshEnterprise.Bpmn.Subscription.Authority do
  @moduledoc """
  Who the steps of a recipe's process run as.

  A recipe is a subscription: when a committed row lands in a tenant's audit chain, if
  its guard and route say so, start a published process. The event that fires it grants
  nothing. What the process may do comes from the subscription's `authority`, chosen while
  the row is a draft and fixed when it is published:

  | Value | Who runs service and send tasks |
  |---|---|
  | `:human_tasks_only` (default) | Nobody. Publishing refuses a diagram with a service, send or script task or a call activity, and a process that reaches one anyway runs nothing (`AshEnterprise.Process.RecipeAuthority`) |
  | `:causing_person` | The person whose write caused the event, as the engine already runs it. Allowed only for the keys in `causing_person_keys/0`, which holds exactly one |
  | `:standing_grant` | The `recipe_runner` automation principal acting for the person who published the version (`accountable_person_id`), on the intersection of the two, rebuilt at every claim. Only `publish_granted`, a person's own act, publishes it; `publish` refuses it |

  ## The causing-person allowlist

  `:causing_person` makes the writer of an event the authority for whatever the process
  then does, which is a confused deputy unless the writer really is the person asking. So
  it is limited to a reviewed list in config, holding one key:

      config :ash_enterprise, AshEnterprise.Bpmn.Subscription,
        causing_person_keys: ["access_request.submitted"]

  A list of any other length refuses every key, so widening it is a code review, not a
  config edit that quietly works. Forms and packs never select it: only a system actor,
  the setup path, may choose it on a draft (`Validations.AuthoritySelectable`).

  ## The standing grant

  `publish_granted` stamps the person publishing as the version's accountable person and
  writes them an `AshEnterprise.Security.AgentStartGrant` keyed `grant_key/1`,
  `recipe:<key>:<version>`, valid for `grant_review_days/0` days. A step of the process runs
  only while that person is an active member of the tenant and holds that grant, and does
  only what both they and the `recipe_runner`'s roles allow. A new version is a new key, so
  it never inherits an earlier version's grant; a version whose publisher has left, or whose
  grant has lapsed or been revoked, runs nothing until a person publishes it again.

  Nobody else writes that grant: `AgentStartGrant`'s `grant` refuses a `recipe:` key, so an
  administrator cannot revive, extend or share one, and only the publisher's own row counts,
  never one held through a team. Nor does the grant reach a diagram the publisher did not
  see: `publish_granted` stamps the definitions it validated (`granted_definition_ids`), and
  a step of any other definition, a later version under the key or a call activity's child
  included, runs nothing. A standing grant names its process: a decision route is refused.

      config :ash_enterprise, AshEnterprise.Bpmn.Subscription,
        standing_grant_review_days: 365
  """

  @values [:human_tasks_only, :causing_person, :standing_grant]

  @grant_prefix "recipe:"

  # The node types that do work rather than wait for a person. A call activity is here
  # because what it calls is another diagram, which this check cannot see at publish.
  @acting_node_types ~w(serviceTask sendTask scriptTask callActivity)

  @doc "Every authority a subscription may carry."
  @spec values() :: [atom()]
  def values, do: @values

  @doc "The node types a `:human_tasks_only` process may not contain."
  @spec acting_node_types() :: [String.t()]
  def acting_node_types, do: @acting_node_types

  @doc """
  The start grant a `:standing_grant` version's steps run under, one per version:
  `recipe:<key>:<version>`.
  """
  @spec grant_key(map()) :: String.t()
  def grant_key(%{key: key, version: version}), do: @grant_prefix <> "#{key}:#{version}"

  @doc """
  Whether `agent_key` names a recipe version's start grant. Only `publish_granted` writes
  one (`AshEnterprise.Security.Validations.NotARecipeGrant`).
  """
  @spec grant_key?(String.t()) :: boolean()
  def grant_key?(agent_key) when is_binary(agent_key),
    do: String.starts_with?(agent_key, @grant_prefix)

  @doc "How many days a standing grant lasts before its publisher must publish it again."
  @spec grant_review_days() :: pos_integer()
  def grant_review_days do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Bpmn.Subscription, [])
    |> Keyword.get(:standing_grant_review_days, 365)
  end

  @doc "The subscription keys that may run as the causing person, from config."
  @spec causing_person_keys() :: [String.t()]
  def causing_person_keys do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Bpmn.Subscription, [])
    |> Keyword.get(:causing_person_keys, [])
  end

  @doc """
  Whether a subscription keyed `key` may run as the causing person: the allowlist holds
  exactly one key, and it is this one.
  """
  @spec causing_person?(String.t() | nil) :: boolean()
  def causing_person?(key) do
    case causing_person_keys() do
      [^key] when is_binary(key) -> true
      _ -> false
    end
  end

  @doc """
  The nodes of a compiled graph that would act rather than wait for a person, as
  `{node_id, type}`, sorted by id.
  """
  @spec acting_nodes(map() | nil) :: [{String.t(), String.t()}]
  def acting_nodes(%{"nodes" => nodes}) when is_map(nodes) do
    nodes
    |> Enum.filter(fn {_id, node} -> is_map(node) and node["type"] in @acting_node_types end)
    |> Enum.map(fn {id, node} -> {id, node["type"]} end)
    |> Enum.sort()
  end

  def acting_nodes(_graph), do: []
end
