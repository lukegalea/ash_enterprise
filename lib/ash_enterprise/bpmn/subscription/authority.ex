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
  | `:standing_grant` | Not published by `publish`: a person's standing grant is published by that person, not by the setup task or a system actor |

  ## The causing-person allowlist

  `:causing_person` makes the writer of an event the authority for whatever the process
  then does, which is a confused deputy unless the writer really is the person asking. So
  it is limited to a reviewed list in config, holding one key:

      config :ash_enterprise, AshEnterprise.Bpmn.Subscription,
        causing_person_keys: ["access_request.submitted"]

  A list of any other length refuses every key, so widening it is a code review, not a
  config edit that quietly works. Forms and packs never select it: only a system actor,
  the setup path, may choose it on a draft (`Validations.AuthoritySelectable`).
  """

  @values [:human_tasks_only, :causing_person, :standing_grant]

  # The node types that do work rather than wait for a person. A call activity is here
  # because what it calls is another diagram, which this check cannot see at publish.
  @acting_node_types ~w(serviceTask sendTask scriptTask callActivity)

  @doc "Every authority a subscription may carry."
  @spec values() :: [atom()]
  def values, do: @values

  @doc "The node types a `:human_tasks_only` process may not contain."
  @spec acting_node_types() :: [String.t()]
  def acting_node_types, do: @acting_node_types

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
