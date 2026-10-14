defmodule AshEnterprise.Mdm.TestSupport do
  @moduledoc """
  Shared helpers for the MDM host tests: a tenant, a person actor (the
  System One conformance drill), and Mapping lifecycle shorthands.
  """

  alias AshEnterprise.Mdm.Mapping

  @doc "A tenant id — MDM resources scope by organization_id; no org row is needed."
  def tenant, do: Ash.UUID.generate()

  defdelegate person_actor!(opts \\ []), to: AshEnterprise.SystemOne.Support, as: :person

  def person_rules do
    [
      %{"path" => "Email", "target" => "email", "op" => "trim", "args" => %{}},
      %{"path" => "Full Name", "target" => "name", "op" => "identity", "args" => %{}}
      # Canonical.Person carries exactly name + email beyond the base's
      # system attributes — total accounting is two rules.
    ]
  end

  def draft_host_mapping!(tenant, opts) do
    attrs =
      Keyword.merge(
        [
          direction: :ingress,
          source: "manual_csv",
          stream: "acme_contacts",
          target_resource: "AshEnterprise.Canonical.Person",
          field_rules: person_rules(),
          observed_schema: %{"Email" => %{}, "Full Name" => %{}}
        ],
        opts
      )
      |> Map.new()

    Mapping
    |> Ash.Changeset.for_create(:draft, attrs, tenant: tenant, authorize?: false)
    |> Ash.create!(tenant: tenant, authorize?: false)
  end

  def validate_host_mapping!(mapping, tenant) do
    mapping
    |> Ash.Changeset.for_update(:validate, %{}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)
  end

  def activate_host_mapping!(mapping, tenant, person) do
    mapping
    |> validate_host_mapping!(tenant)
    |> Ash.reload!(tenant: tenant, authorize?: false)
    |> Ash.Changeset.for_update(:activate, %{activation_note: "test"},
      tenant: tenant,
      actor: person,
      authorize?: true
    )
    |> Ash.update!(tenant: tenant, actor: person, authorize?: true)
  end

  @doc """
  The review-queue fixture: a golden person, a landed source record, a
  staged row mapped from it, and a review-banded candidate pairing them —
  the state the pipeline produces before a steward decides.
  """
  def staged_candidate!(org, admin, name, email) do
    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(:upsert_from_source, %{
        name: name <> " Existing",
        email: nil,
        owner_id: admin.id,
        owning_business_unit_id: admin.owning_business_unit_id
      })
      |> Ash.create!(tenant: org, authorize?: false)

    {:ok, source_record} =
      AshEnterprise.Mdm.Landing.land_row(
        org,
        "acme_contacts",
        %{"Full Name" => name, "Email" => email},
        row_key: "cand-#{System.unique_integer([:positive])}"
      )

    mapping = activate_host_mapping!(draft_host_mapping!(org, []), org, admin)

    batch =
      AshEnterprise.Mdm.ImportBatch
      |> Ash.Changeset.for_create(:open, %{mapping_id: mapping.id, source_slug: "acme_contacts"},
        tenant: org,
        authorize?: false
      )
      |> Ash.create!(tenant: org, authorize?: false)

    staged =
      AshEnterprise.Mdm.StagedRecord
      |> Ash.Changeset.for_create(:stage, %{
        batch_id: batch.id,
        source_record_id: source_record.id,
        mapped: %{"name" => name, "email" => email}
      })
      |> Ash.create!(tenant: org, authorize?: false)

    AshEnterprise.Mdm.MatchCandidate
    |> Ash.Changeset.for_create(:create, %{
      staged_record_id: staged.id,
      golden_resource: "AshEnterprise.Canonical.Person",
      golden_id: golden.id,
      score: Decimal.new("0.72"),
      explanation: %{"rules" => [%{"rule" => "email_exact", "score" => "1.0"}]}
    })
    |> Ash.create!(tenant: org, authorize?: false)
    |> then(fn candidate ->
      candidate
      |> Ash.Changeset.for_update(:update, %{band: :review}, tenant: org, authorize?: false)
      |> Ash.update!(tenant: org, authorize?: false)
    end)
    |> then(&{&1, staged, golden})
  end

  def stringify(nil), do: nil

  def stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  def stringify(other), do: other
end
