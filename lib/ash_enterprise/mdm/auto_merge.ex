defmodule AshEnterprise.Mdm.AutoMerge do
  @moduledoc """
  The machine half of band routing (MDM-4/5): what happens to a staged
  record and its candidate when the band table has already decided.

  * `:admit` — the candidate pairs the staged row with an existing golden at
    a score the tenant has pre-authorised: the staged values become statements
    and the golden refolds under the governing survivorship policy
    (`AshEnterprise.Mdm.Refold`), the source identity opens at the golden, the staged row is `:merged` and the
    candidate `:auto_merged`. No verdict rows: nobody decided anything; the
    published band table did, and its certification is the provenance.
  * `:omit` — no golden fits: the staged row becomes a golden of its own
    (`:created`), its identity opens there, and the candidate is
    `:superseded` — the pairing it proposed is moot.

  The steward half (judgment, HumanVerdict, the person gate) lives in
  `StewardVerdict`; nothing here ever sets a person state.
  """

  alias AshEnterprise.Mdm.{Refold, SourceIdentity, SourceRecord}

  @doc "Runs the admit band: fold into the golden, open the identity, spend the row."
  def admit!(candidate, staged, golden, tenant) do
    fold!(staged, golden, tenant)
    open_identity!(staged, candidate, tenant)

    staged
    |> Ash.Changeset.for_update(:update, %{status: :merged}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    candidate
    |> Ash.Changeset.for_update(:update, %{status: :auto_merged},
      tenant: tenant,
      actor: AshEnterprise.Platform.SystemActor.system(),
      authorize?: true
    )
    |> Ash.update!(
      tenant: tenant,
      actor: AshEnterprise.Platform.SystemActor.system(),
      authorize?: true
    )
  end

  @doc "Runs the omit band: the staged row becomes its own golden, the candidate is superseded."
  def new_golden!(candidate, staged, owner, tenant)

  def new_golden!(nil, staged, owner, tenant) do
    golden = create_golden!(staged, owner, tenant)

    staged
    |> Ash.Changeset.for_update(:update, %{status: :created}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    golden
  end

  def new_golden!(candidate, staged, owner, tenant) do
    golden = create_golden!(staged, owner, tenant)

    staged
    |> Ash.Changeset.for_update(:update, %{status: :created}, tenant: tenant, authorize?: false)
    |> Ash.update!(tenant: tenant, authorize?: false)

    candidate
    |> Ash.Changeset.for_update(:update, %{status: :superseded},
      tenant: tenant,
      actor: AshEnterprise.Platform.SystemActor.system(),
      authorize?: true
    )
    |> Ash.update!(
      tenant: tenant,
      actor: AshEnterprise.Platform.SystemActor.system(),
      authorize?: true
    )

    golden
  end

  # The staged row becomes a golden of its own. Deliberately a plain
  # upsert-free create via the same replay write: the omit band ruled out a
  # merge, so an email collision must NOT overwrite the existing person.
  # The unique_email identity makes the create fail loudly instead, and the
  # caller routes that row back to stewardship.
  def create_golden!(staged, owner, tenant) do
    mapped = staged.mapped || %{}

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(
        :mdm_create_golden,
        %{
          name: mapped["name"],
          email: mapped["email"],
          owner_id: owner.id,
          owning_business_unit_id: owner.owning_business_unit_id
        },
        tenant: tenant,
        authorize?: false
      )
      |> Ash.create!(tenant: tenant, authorize?: false)

    open_identity!(staged, "AshEnterprise.Canonical.Person", golden.id, tenant)
    Refold.assert!(tenant, golden.id, staged_values(staged), staged_origin(staged))

    golden
  end

  @doc "The staged values become statements about the golden, and it refolds."
  def fold!(staged, golden, tenant) do
    Refold.assert!(tenant, golden.id, staged_values(staged), staged_origin(staged))
    Refold.refold!(tenant, golden.id)

    :ok
  end

  defp staged_values(staged), do: Map.take(staged.mapped || %{}, Refold.attributes())

  # The landing's own observation time, so a retried job is the same statement.
  defp staged_origin(staged) do
    source_record = Ash.get!(SourceRecord, staged.source_record_id, authorize?: false)

    %{
      origin_kind: :import,
      source: to_string(source_record.source),
      origin_ref: %{"source_record_id" => source_record.id, "staged_record_id" => staged.id},
      observed_at: source_record.fetched_at
    }
  end

  @doc "Opens the staged row's source identity at the candidate's golden."
  def open_identity!(staged, candidate, tenant) do
    open_identity!(staged, candidate, candidate.golden_id, tenant)
  end

  def open_identity!(staged, _candidate, golden_id, tenant) do
    source_record = Ash.get!(SourceRecord, staged.source_record_id, authorize?: false)

    SourceIdentity
    |> Ash.Changeset.for_create(
      :open,
      %{
        source: to_string(source_record.source),
        stream: to_string(source_record.stream),
        external_id: source_record.external_id,
        golden_resource: "AshEnterprise.Canonical.Person",
        golden_id: golden_id,
        asserted_by: :mapping,
        confidence: nil
      },
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!(tenant: tenant, authorize?: false)

    :ok
  end
end
