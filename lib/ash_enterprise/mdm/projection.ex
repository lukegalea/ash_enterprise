defmodule AshEnterprise.Mdm.Projection do
  @moduledoc """
  The golden-record replay (ADR 0053 §7, MDM-5): rebuild canonical state
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
    mapping = active_ingress_mapping(tenant)
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
          |> Enum.map(&AshMdm.Mapping.Evaluator.run(mapping.field_rules, &1.raw_payload))

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
      direction == ^:ingress and status == ^:active and target_resource == ^@golden
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
