defmodule AshEnterprise.Mdm.Export do
  @moduledoc """
  The egress run (MDM-6, ADR 0050 §8): customer-shaped rows built from
  golden records, through the tenant's active `:egress` mapping.

  The disclosure gate is the export action itself (ADR 0042 keeps admission
  at land; this is the *departure* check) — and it rests on the tags
  recorded at land, never on caller input: each golden's residency is the
  residency tag of the SourceRecords its SourceIdentities point at. A
  `us`-landed record cannot leave to a zone whose restrictions exclude it,
  no matter who asks. A golden with no residency tag at all is untagged, and
  untagged data is refused. Merged-away rows (absorbed losers) are not
  exported.

  The action is person-gated and grant-checked by the Person resource's
  policies; this module is only the run. Write-back to customer systems is
  the roadmap's separate `outbound events` item — this is export/pull only.
  """

  require Ash.Query

  @data_class :customer_confidential

  # The generic action's run: `input` carries the declared destination zone,
  # `context` the tenant and the (already policy-checked) actor.
  @doc false
  def run(input, _opts, context) do
    tenant = context.tenant
    zone_id = Map.get(input.arguments || %{}, :zone)

    with {:ok, zone} <- AshEnterprise.Zones.fetch(zone_id),
         {:ok, mapping} <- active_egress_mapping(tenant) do
      with {:ok, goldens} <- gated(goldens(tenant), zone, zone_id) do
        {:ok, rows(goldens, mapping)}
      end
    end
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

  defp goldens(tenant) do
    # A golden is a Person some SourceIdentity points at, and not an
    # absorbed loser: merged rows were folded into their survivor.
    AshEnterprise.Canonical.Person
    |> Ash.Query.filter(merged == false)
    |> Ash.Query.filter(exists(AshEnterprise.Mdm.SourceIdentity, golden_id == parent(id)))
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  # The gate: row by row, on the residency the land recorded. One
  # inadmissible or untagged golden refuses the export whole — a partial
  # export would leak the presence of the rows it withheld.
  defp gated(goldens, zone, zone_id) do
    goldens
    |> Enum.reduce_while({:ok, goldens}, fn golden, {:ok, _} ->
      case residency(golden) do
        {:ok, tags} ->
          # The land tags are bizev's lowercase region atoms ("ca"); the
          # zone admission vocabulary is the ISO code ("CA"). Every tag the
          # row carries must admit.
          refusals =
            tags
            |> Enum.map(&String.upcase(&1))
            |> Enum.map(
              &AshEnterprise.Zones.admit(zone, %{data_class: @data_class, residency: &1})
            )
            |> Enum.reject(&(&1 == :ok))

          case refusals do
            [] ->
              {:cont, {:ok, goldens}}

            [{:error, reason} | _] ->
              {:halt,
               {:error,
                Ash.Error.Forbidden.exception(
                  errors: [
                    Ash.Error.Forbidden.Policy.exception(
                      custom_message:
                        "mdm egress disclosure gate: golden #{golden.id} cannot leave to zone #{zone_id}: #{inspect(reason)}"
                    )
                  ]
                )}}
          end

        :error ->
          {:halt,
           {:error,
            Ash.Error.Forbidden.exception(
              errors: [
                Ash.Error.Forbidden.Policy.exception(
                  custom_message:
                    "mdm egress disclosure gate: golden #{golden.id} carries no residency tag"
                )
              ]
            )}}
      end
    end)
  end

  defp residency(golden) do
    tags =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(
        golden_id == ^golden.id and golden_resource == "AshEnterprise.Canonical.Person"
      )
      |> Ash.read!(tenant: golden.organization_id, authorize?: false)
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

    Enum.map(persons, fn person ->
      Enum.reduce(rules, %{}, fn rule, row ->
        case egress_value(rule, person) do
          :skip -> row
          value -> Map.put(row, rule["target"], value)
        end
      end)
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
