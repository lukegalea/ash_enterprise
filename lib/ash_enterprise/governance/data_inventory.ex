defmodule AshEnterprise.Governance.DataInventory do
  @moduledoc """
  A generated inventory of what this application stores: one entry per
  resource in the configured domains, read from the declarations the resource
  was compiled with, plus the register of egress paths
  (`AshEnterprise.Governance.DataFlows`). Written to `docs/data-inventory.json`
  by `mix ash_enterprise.data_inventory`, which CI runs with `--check`.

  ## What it is

  A read-only description of declared schema and ownership kind: the domain,
  table, ownership, whether the table is tenant-scoped or global, audit,
  archival and lifecycle switches, CDM provenance, API exposure, and which
  attributes are `sensitive?` or sealed. It uses the column names ADR 0013
  chose for a catalogue; it makes no claim of compatibility with any
  catalogue's schema, because nothing here checks one.

  ## What it is not

  It names no steward. Ownership here is a resource-level kind
  (`:user_owned`, `:business_owned`, ...), which says who may be granted
  access, not who is accountable for the data; accountable people are a
  deployment owner's input. And it does not attest what a running deployment
  holds: it describes the code.

  ## Classification is derived, never declared

  An attribute is `sensitive` when it says `sensitive? true`, `sealed` when it
  is an `encrypted_*` column (the cloaked attributes, sealed under an erasure
  scope or the application vault), and otherwise carries no class. A narrow
  name heuristic (`looks_personal?/1`) flags attributes that look like personal
  data. A flagged attribute must be sensitive, sealed, or listed with a reason
  in `DataFlows.looks_personal_exceptions/0`; one that is none of these is
  `unclassified`, and `unclassified/1` is what a test asserts is empty.

  The heuristic is a guess. Too narrow misses personal data; too broad makes
  the exceptions list noise. It starts narrow and is read as a floor.
  """

  alias AshEnterprise.Governance.DataFlows

  @personal ~r/(^|_)(email|phone|first_name|last_name|birth\w*|address|national_id)($|_)/

  @doc "The attribute-name heuristic for personal data."
  @spec looks_personal?(atom() | String.t()) :: boolean()
  def looks_personal?(name), do: Regex.match?(@personal, to_string(name))

  @doc "The resources inventoried: every resource in the configured domains."
  @spec resources() :: [module()]
  def resources do
    :ash_enterprise
    |> Application.get_env(:ash_domains, [])
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.concat(AshEnterprise.Platform.Seeder.platform_resources())
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
  end

  @doc "The full document: resources, global tables and the egress register."
  @spec build() :: map()
  def build, do: build(resources(), DataFlows.looks_personal_exceptions(), DataFlows.all())

  @doc false
  def build(resources, exceptions, flows) do
    entries = Enum.map(resources, &entry(&1, exceptions))

    %{
      "format" => "ash_enterprise.data_inventory/1",
      "note" =>
        "Generated from the resource declarations by `mix ash_enterprise.data_inventory`; do not edit. " <>
          "It describes the code, names no data steward, and attests nothing about a running deployment.",
      "summary" => %{
        "resources" => length(entries),
        "tenant_scoped" => Enum.count(entries, &(&1["tenancy"] != "global")),
        "global_tables" => length(global_tables(entries)),
        "with_sensitive_attributes" => Enum.count(entries, &(&1["sensitive_attributes"] != [])),
        "with_sealed_attributes" => Enum.count(entries, &(&1["sealed_attributes"] != [])),
        "unclassified_personal_attributes" => length(unclassified(entries)),
        "egress_paths" => length(flows)
      },
      "resources" => entries,
      "global_tables" => global_tables(entries),
      "egress_register" => Enum.map(flows, &flow/1)
    }
  end

  # A table with no tenant column or tenant context: one table that every
  # tenant's rows share, or that holds no tenant's rows at all. Resources with
  # no table of their own (computed, in-memory) are not tables.
  defp global_tables(entries),
    do: for(e <- entries, e["tenancy"] == "global", e["table"] != nil, do: e["resource"])

  @doc """
  Personal-looking attributes with no class: neither sensitive, sealed nor
  excepted with a reason. `source` is a built document or its resource entries.
  """
  @spec unclassified(map() | [map()]) :: [map()]
  def unclassified(%{"resources" => entries}), do: unclassified(entries)

  def unclassified(entries) when is_list(entries) do
    for entry <- entries,
        attribute <- entry["personal_looking_attributes"],
        attribute["class"] == "unclassified" do
      %{"resource" => entry["resource"], "attribute" => attribute["attribute"]}
    end
  end

  @doc "One resource's entry."
  @spec entry(module(), map()) :: map()
  def entry(resource, exceptions) do
    attributes = Ash.Resource.Info.attributes(resource)
    platform? = AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource)
    extensions = Spark.extensions(resource)

    sensitive = for a <- attributes, a.sensitive?, do: to_string(a.name)
    sealed_names = for a <- attributes, sealed?(a.name), do: a.name
    sealing = sealing(resource)

    %{
      "resource" => inspect(resource),
      "domain" => inspect(Ash.Resource.Info.domain(resource)),
      "data_layer" => inspect(Ash.Resource.Info.data_layer(resource)),
      "table" => table(resource),
      "platform_resource" => platform?,
      "ownership" => platform_opt(resource, platform?, :ownership, :none) |> stringify(),
      "tenancy" => tenancy(resource),
      "tenant_option" => platform_opt(resource, platform?, :tenant?, nil),
      "audit" => audit?(resource, platform?, extensions),
      "archival" => AshArchival.Resource in extensions,
      "lifecycle" => platform_opt(resource, platform?, :lifecycle?, nil),
      "cdm_entity" => platform_opt(resource, platform?, :cdm_entity, nil),
      "api_type" => platform_opt(resource, platform?, :api_type, nil) |> stringify(),
      "sensitive_attributes" => Enum.sort(sensitive),
      "sealed_attributes" =>
        sealed_names
        |> Enum.sort()
        |> Enum.map(&%{"attribute" => to_string(&1), "sealing" => sealing}),
      "personal_looking_attributes" =>
        for a <- attributes, looks_personal?(a.name) do
          {class, reason} = classify(resource, a, exceptions)
          %{"attribute" => to_string(a.name), "class" => class, "reason" => reason}
        end
        |> Enum.sort_by(& &1["attribute"])
    }
  end

  defp classify(resource, attribute, exceptions) do
    cond do
      attribute.sensitive? -> {"sensitive", nil}
      sealed?(attribute.name) -> {"sealed", nil}
      reason = Map.get(exceptions, {resource, attribute.name}) -> {"excepted", reason}
      true -> {"unclassified", nil}
    end
  end

  defp sealed?(name), do: String.starts_with?(to_string(name), "encrypted_")

  # Sealed under an erasure scope when an action runs the scope-sealing change,
  # otherwise by the application vault (`ash_cloak` default).
  defp sealing(resource) do
    if scope_sealed?(resource), do: "erasure_scope", else: "application_vault"
  end

  defp scope_sealed?(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.flat_map(&Map.get(&1, :changes, []))
    |> Enum.concat(Ash.Resource.Info.changes(resource))
    |> Enum.any?(fn
      %{change: {AshEnterprise.Erasure.Changes.SealUnderScope, _}} -> true
      _ -> false
    end)
  end

  defp table(resource) do
    if Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
      do: AshPostgres.DataLayer.Info.table(resource),
      else: nil
  end

  defp tenancy(resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil -> "global"
      strategy -> to_string(strategy)
    end
  end

  defp audit?(resource, platform?, extensions) do
    if platform?,
      do: platform_opt(resource, true, :audit?, nil),
      else: AshEvents.Events in extensions
  end

  defp platform_opt(_resource, false, _key, default), do: default

  defp platform_opt(resource, true, key, default),
    do: Spark.Dsl.Extension.get_opt(resource, [:platform], key, default)

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp flow(row) do
    %{
      "id" => to_string(row.id),
      "name" => row.name,
      "recipient_class" => to_string(row.recipient_class),
      "data_classes" => Enum.map(row.data_classes, &to_string/1),
      "gate" => gate(row.gate),
      "known_gap" => row.known_gap,
      "modules" => row.modules |> Enum.map(&inspect/1) |> Enum.sort(),
      "notes" => row.notes
    }
    |> maybe_put("operation", Map.get(row, :operation))
  end

  defp gate(:none), do: "none"

  defp gate(%{name: name, enforced_by: module}),
    do: %{"name" => name, "enforced_by" => inspect(module)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Encodes a document as pretty JSON with keys in a fixed order, so the file is
  byte-stable. Top-level and entry keys keep the order they are written in
  `build/3`; everything else is sorted.
  """
  @spec encode(map()) :: String.t()
  def encode(document), do: Jason.encode!(ordered(document), pretty: true) <> "\n"

  @key_order ~w(format note summary resources global_tables egress_register
                resource domain data_layer table platform_resource ownership tenancy tenant_option
                audit archival lifecycle cdm_entity api_type sensitive_attributes sealed_attributes
                personal_looking_attributes
                id name recipient_class data_classes gate known_gap modules notes operation)

  defp ordered(%{} = map) do
    pairs =
      map
      |> Enum.sort_by(fn {k, _} -> {Enum.find_index(@key_order, &(&1 == k)) || 999, k} end)
      |> Enum.map(fn {k, v} -> {k, ordered(v)} end)

    Jason.OrderedObject.new(pairs)
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
