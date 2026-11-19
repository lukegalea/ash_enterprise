defmodule AshEnterprise.Integration.Outbound.Catalogue do
  @moduledoc """
  What an outbound webhook endpoint may subscribe to: the create, update and destroy of
  every audited resource that has a public API type (the `api_type` option of
  `AshEnterprise.Platform.Resource`). That is what a tenant's API key can read anyway, so a
  subscription never names something the API does not publish.

  Each entry is a CloudEvents `type`, `ash_enterprise.<resource>.<action_type>`, where
  `<resource>` is the resource module's last segment in snake case
  (`ash_enterprise.team.create`). The integration and process domains are never in it,
  so a delivery cannot be the event that causes another delivery.

  Derived from the domains on every call to `entries/0` the first time, then held in
  `:persistent_term`: the set changes only with the code.
  """

  @excluded_domains [AshEnterprise.Integration, AshEnterprise.Bpmn, AshEnterprise.Process]
  @actions [:create, :update, :destroy]
  @key {__MODULE__, :entries}

  @type entry :: %{type: String.t(), resource: module(), action_type: atom()}

  @doc "Every subscribable event type, sorted by type."
  @spec entries() :: [entry()]
  def entries do
    case :persistent_term.get(@key, nil) do
      nil ->
        entries = build()
        :persistent_term.put(@key, entries)
        entries

      entries ->
        entries
    end
  end

  @doc "The subscribable type names."
  @spec types() :: [String.t()]
  def types, do: Enum.map(entries(), & &1.type)

  @doc "Whether `type` is in the catalogue."
  @spec type?(term()) :: boolean()
  def type?(type) when is_binary(type), do: type in types()
  def type?(_type), do: false

  @doc "The catalogue entries for some type names (unknown names are dropped)."
  @spec for_types([String.t()]) :: [entry()]
  def for_types(types) do
    wanted = MapSet.new(types)
    Enum.filter(entries(), &MapSet.member?(wanted, &1.type))
  end

  @doc "The type an audit event has, or nil when the event is not subscribable."
  @spec type_of(module() | nil, atom() | String.t() | nil) :: String.t() | nil
  def type_of(resource, action_type) do
    action_type = if is_binary(action_type), do: action_type, else: to_string(action_type)

    Enum.find_value(entries(), fn entry ->
      if entry.resource == resource and Atom.to_string(entry.action_type) == action_type,
        do: entry.type
    end)
  end

  defp build do
    for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
        domain not in @excluded_domains,
        resource <- Ash.Domain.Info.resources(domain),
        published?(resource),
        AshEnterprise.Audit.EventSource.audited?(resource),
        action_type <- @actions do
      %{type: type(resource, action_type), resource: resource, action_type: action_type}
    end
    |> Enum.sort_by(& &1.type)
  end

  defp published?(resource) do
    AshEnterprise.Platform.SystemAttributes in Ash.Resource.Info.extensions(resource) and
      not is_nil(Spark.Dsl.Extension.get_opt(resource, [:platform], :api_type, nil))
  end

  defp type(resource, action_type) do
    name = resource |> Module.split() |> List.last() |> Macro.underscore()
    "ash_enterprise.#{name}.#{action_type}"
  end
end
