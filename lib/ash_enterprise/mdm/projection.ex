defmodule AshEnterprise.Mdm.Projection do
  @moduledoc """
  The golden-record replay (ADR 0054 §7, MDM-5): rebuild canonical state
  from SourceRecords + the active ingress mapping + the identity history.

  Determinism contract (mirrors `AshEnterprise.Canonical.Projection`):
  delete the goldens, replay, and the rows come back identical — ids
  included, because each golden is recreated with the id its SourceIdentities
  pin. The identity history IS the recorded decision: a steward confirm, an
  admit band's auto-merge and a reject's new-golden all opened or repointed
  identities, and replay follows wherever they point.

  `merged`/`master_id` are deliberately NOT written: they default false/nil,
  so replay never resurrects merge state. Deterministic scores only — an LLM
  observation is a recorded fact by replay time; replay never re-asks.
  """

  require Ash.Query

  @golden "AshEnterprise.Canonical.Person"

  @doc "Rebuilds golden records for the tenant. Returns {:ok, count}."
  def replay(opts) do
    tenant = Keyword.fetch!(opts, :tenant)

    mappings = %{
      csv: active_ingress_mapping(tenant),
      people: AshEnterprise.Mdm.People.mapping(tenant)
    }

    owner = deterministic_owner(tenant)

    identities =
      AshEnterprise.Mdm.SourceIdentity
      |> Ash.Query.filter(golden_resource == ^@golden and not is_nil(golden_id))
      |> Ash.Query.sort(golden_id: :asc, inserted_at: :asc)
      |> Ash.read!(tenant: tenant, authorize?: false)

    goldens =
      identities
      |> Enum.group_by(& &1.golden_id)
      |> Enum.map(fn {golden_id, ids} ->
        values =
          ids
          |> Enum.map(&source_record_for/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&evaluate(mappings, &1))
          |> own_first(golden_id)

        %{
          id: golden_id,
          name: first_value(values, "name"),
          email: first_value(values, "email")
        }
      end)

    Enum.each(goldens, fn golden ->
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(
        :mdm_replay_golden,
        %{
          golden_id: golden.id,
          name: golden.name,
          email: golden.email,
          owner_id: owner.id,
          owning_business_unit_id: owner.owning_business_unit_id
        },
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!(tenant: tenant, authorize?: false)
    end)

    {:ok, length(goldens)}
  end

  # Each landing through its own source's mapping: the CSV upload's, or the
  # people source's (PROD-9).
  defp evaluate(mappings, record) do
    mapping =
      if record.source == AshEnterprise.Mdm.People.source(),
        do: mappings.people,
        else: mappings.csv

    case mapping do
      nil -> []
      mapping -> [AshMdm.Mapping.Evaluator.run(mapping.field_rules, record.raw_payload)]
    end
  end

  # A people landing names the person row it observed. When a merge moved
  # another person's identities to this golden, the golden's OWN
  # observations still decide its values — never the absorbed address.
  defp own_first(evaluations, golden_id) do
    {own, others} =
      Enum.split_with(evaluations, fn
        {:ok, %{"person_id" => ^golden_id}} -> true
        _ -> false
      end)

    own ++ others
  end

  # First non-nil value wins, in identity order — a deterministic fold that
  # never mixes two identities' values into one field.
  defp first_value(evaluations, field) do
    evaluations
    |> Enum.flat_map(fn
      {:ok, mapped} -> [mapped[field]]
      _ -> []
    end)
    |> Enum.find(&(not is_nil(&1)))
  end

  # The owner is a per-tenant constant: the earliest-created user. Same
  # inputs, same replay, same owner — determinism over attribution (who
  # owned the row is in the identity's asserted_by history).
  # The owner is a per-tenant constant: the earliest-created user whose
  # business unit belongs to THIS tenant (User is tenant?: false, so the
  # filter is explicit — replay never adopts another customer's user). Same
  # inputs, same replay, same owner; attribution lives in the identity's
  # asserted_by history.
  defp deterministic_owner(tenant) do
    bu_ids =
      AshEnterprise.Accounts.BusinessUnit
      |> Ash.Query.select([:id])
      |> Ash.Query.filter(organization_id == ^tenant)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    AshEnterprise.Accounts.User
    |> Ash.Query.filter(owning_business_unit_id in ^bu_ids)
    |> Ash.Query.sort(created_on: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp active_ingress_mapping(tenant) do
    AshEnterprise.Mdm.Mapping
    |> Ash.Query.filter(
      direction == ^:ingress and status == ^:active and target_resource == ^@golden and
        source != ^AshEnterprise.Mdm.People.mapping_source()
    )
    |> Ash.Query.sort(version: :desc)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
  end

  defp source_record_for(identity) do
    AshEnterprise.Mdm.SourceRecord
    |> Ash.Query.filter(
      source == ^identity.source and stream == ^identity.stream and
        external_id == ^identity.external_id
    )
    |> Ash.Query.sort(fetched_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end
end
