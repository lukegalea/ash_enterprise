defmodule AshEnterprise.Mdm.Export do
  @moduledoc """
  The egress run (MDM-6; ADR 0054 and its 2026-10-16 addendum): customer-shaped
  rows built from golden records, through the tenant's active `:egress`
  mapping. The action is `AshEnterprise.Mdm.Egress.export`; this module is
  only its run.

  ## Authorized by the egress grant, and only as far as it reaches

  The action's policy is the platform grant union over
  `AshEnterprise.Mdm.Egress` — a `read` grant on the egress resource, held by
  stewards, answered from the precomputed `ActorContext`. Having passed it,
  the run reads the golden persons without a second policy evaluation
  (`authorize?: false`), and that read is deliberately narrow:

    * **the actor's own tenant** — the grant is a row in the tenant that holds
      it; any other tenant is refused before anything is read;
    * **golden persons only** — Person's `:goldens` read: some SourceIdentity
      points at it, and no merge absorbed it;
    * **the fields the egress mapping names** — public Person attributes only,
      selected, so nothing else is loaded; a rule naming anything else
      refuses the export.

  Person itself stays owner-only for every other read, mail included.

  ## The disclosure gate

  The gate (ADR 0042 keeps admission at land; this is the *departure* check)
  rests on the tags recorded at land, never on caller input: each golden's
  residency is the residency tag of the SourceRecords its SourceIdentities
  point at. A `us`-landed record cannot leave to a zone whose restrictions
  exclude it, no matter who asks. A golden with no residency tag at all is
  untagged, and untagged data is refused.

  Write-back to customer systems is the roadmap's separate `outbound events`
  item — this is export/pull only.
  """

  require Ash.Query

  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Security.ActorContext

  @data_class :customer_confidential

  # The generic action's run: `input` carries the declared destination zone,
  # `context` the tenant and the actor that passed the egress grant.
  @doc false
  def run(input, _opts, context) do
    zone_id = Map.get(input.arguments || %{}, :zone)

    with {:ok, tenant} <- egress_tenant(context),
         {:ok, zone} <- AshEnterprise.Zones.fetch(zone_id),
         {:ok, mapping} <- active_egress_mapping(tenant),
         {:ok, fields} <- egress_fields(mapping),
         {:ok, goldens} <- gated(goldens(tenant, fields), tenant, zone, zone_id) do
      {:ok, rows(goldens, mapping)}
    end
  end

  # The tenant whose goldens leave: the call's, which for a person must be the
  # tenant their grant was loaded from — `ActorContext.organization_id` of the
  # same context `RoleGrant` answered with (built without a tenant override,
  # exactly as the check builds it, or the one the request attached). A
  # system actor has no grant of its own and passed through the platform
  # bypass; it exports the tenant it was given.
  defp egress_tenant(%{tenant: nil}), do: refuse("mdm egress needs a tenant")

  defp egress_tenant(%{tenant: tenant, actor: actor}) do
    context = ActorContext.for_actor(actor)

    cond do
      context.system? ->
        {:ok, tenant}

      to_string(context.organization_id) == to_string(tenant) ->
        {:ok, tenant}

      true ->
        refuse("mdm egress: a grant reaches the goldens of its own tenant only")
    end
  end

  defp refuse(message) do
    {:error,
     Ash.Error.Forbidden.exception(
       errors: [Ash.Error.Forbidden.Policy.exception(custom_message: message)]
     )}
  end

  defp active_egress_mapping(tenant) do
    AshEnterprise.Mdm.Mapping
    |> Ash.Query.filter(
      direction == ^:egress and status == ^:active and
        target_resource == "AshEnterprise.Canonical.Person"
    )
    |> Ash.Query.sort(version: :desc)
    |> Ash.read_one(tenant: tenant, authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :no_active_egress_mapping}
      {:ok, mapping} -> {:ok, mapping}
    end
  end

  # The rule ops that carry a golden's value out (the inbound-only ops refuse
  # in `egress_value/2`; anything else exports nothing).
  @value_ops ["identity", "trim"]

  # The attributes the mapping's egress rules read: each must be a public
  # Person attribute, and only those are selected. A rule that names
  # anything else (a private merge column, a relationship) refuses the
  # export rather than reaching past what the grant covers.
  defp egress_fields(mapping) do
    exportable =
      Person |> Ash.Resource.Info.public_attributes() |> Map.new(&{to_string(&1.name), &1.name})

    mapping.field_rules
    |> Enum.filter(&(&1["op"] in @value_ops and not is_nil(&1["path"])))
    |> Enum.map(& &1["path"])
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, fields} ->
      case Map.fetch(exportable, path) do
        {:ok, field} ->
          {:cont, {:ok, [field | fields]}}

        :error ->
          {:halt, refuse("mdm egress: #{inspect(path)} is not an exportable golden attribute")}
      end
    end)
  end

  # The one read the egress grant authorizes: this tenant's golden persons
  # (Person's `:goldens`), the mapped fields and the id only.
  defp goldens(tenant, fields) do
    Person
    |> Ash.Query.for_read(:goldens, %{}, tenant: tenant, authorize?: false)
    |> Ash.Query.select([:id | fields])
    |> Ash.read!()
  end

  # The gate: row by row, on the residency the land recorded. One
  # inadmissible or untagged golden refuses the export whole — a partial
  # export would leak the presence of the rows it withheld.
  defp gated(goldens, tenant, zone, zone_id) do
    goldens
    |> Enum.reduce_while({:ok, goldens}, fn golden, {:ok, _} ->
      case admit(golden, tenant, zone, zone_id) do
        :ok -> {:cont, {:ok, goldens}}
        refused -> {:halt, refused}
      end
    end)
  end

  # One golden at the gate: every tag the row carries must admit.
  defp admit(golden, tenant, zone, zone_id) do
    case residency(golden, tenant) do
      {:ok, tags} ->
        # The land tags are bizev's lowercase region atoms ("ca"); the
        # zone admission vocabulary is the ISO code ("CA").
        tags
        |> Enum.map(&String.upcase(&1))
        |> Enum.map(&AshEnterprise.Zones.admit(zone, %{data_class: @data_class, residency: &1}))
        |> Enum.reject(&(&1 == :ok))
        |> case do
          [] ->
            :ok

          [{:error, reason} | _] ->
            refuse(
              "mdm egress disclosure gate: golden #{golden.id} cannot leave to zone #{zone_id}: #{inspect(reason)}"
            )
        end

      :error ->
        refuse("mdm egress disclosure gate: golden #{golden.id} carries no residency tag")
    end
  end

  defp residency(golden, tenant) do
    tags =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(
        golden_id == ^golden.id and golden_resource == "AshEnterprise.Canonical.Person"
      )
      |> Ash.read!(tenant: tenant, authorize?: false)
      |> Enum.flat_map(&source_record_residencies/1)

    cond do
      tags == [] ->
        :error

      Enum.any?(tags, &is_nil(&1)) ->
        # One untagged source: the row's worst case is untagged, and
        # untagged data does not leave.
        :error

      true ->
        # Every tag the row ever carried, current and historical: the gate
        # loops over all of them and refuses on the first refusal. CA and US
        # are not ordered, so there is no "most restrictive" tag to pick.
        {:ok, Enum.uniq(tags)}
    end
  end

  # A temporal identity has MULTIPLE periods (one SourceRecord row per
  # landed version): every period's tag counts.
  defp source_record_residencies(identity) do
    AshEnterprise.Mdm.SourceRecord
    |> Ash.Query.filter(
      source == ^identity.source and stream == ^identity.stream and
        external_id == ^identity.external_id
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.residency_tag)
  end

  defp rows(persons, mapping) do
    rules = mapping.field_rules

    Enum.map(persons, &row(&1, rules))
  end

  defp row(person, rules) do
    Enum.reduce(rules, %{}, fn rule, row ->
      case egress_value(rule, person) do
        :skip -> row
        value -> Map.put(row, rule["target"], value)
      end
    end)
  end

  defp egress_value(rule, person) do
    value = Map.get(person, safe_atom(rule["path"]))

    case rule["op"] do
      "identity" ->
        present(value)

      "trim" ->
        value && value |> to_string() |> String.trim()

      op when op in ["decode", "cast", "ref_lookup"] ->
        # Inbound-only ops need their tables inverted to egress; refuse the
        # export rather than mis-apply them.
        raise AshEnterprise.Mdm.MatchError,
          message: "export refused: op #{inspect(op)} is not invertible at egress"

      _ ->
        :skip
    end
  end

  defp present(nil), do: :skip
  defp present(value), do: to_string(value)

  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :__no_such_attribute__
  end

  defp safe_atom(name), do: name
end
