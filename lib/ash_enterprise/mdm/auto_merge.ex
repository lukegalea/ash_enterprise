defmodule AshEnterprise.Mdm.AutoMerge do
  @moduledoc """
  The machine half of band routing (MDM-4/5): what happens to a staged
  record and its candidate when the band table has already decided.

  * `:admit` — the candidate pairs the staged row with an existing golden at
    a score the tenant has pre-authorised: survivorship folds the staged
    values into the golden (gaps only — the golden's own values win), the
    source identity opens at the golden, the staged row is `:merged` and the
    candidate `:auto_merged`. No verdict rows: nobody decided anything; the
    published band table did, and its certification is the provenance.
  * `:omit` — no golden fits: the staged row becomes a golden of its own
    (`:created`), its identity opens there, and the candidate is
    `:superseded` — the pairing it proposed is moot.

  The steward half (judgment, HumanVerdict, the person gate) lives in
  `StewardVerdict`; nothing here ever sets a person state.
  """

  require Ash.Query

  alias AshEnterprise.Mdm.{SourceIdentity, SourceRecord, StagedRecord}

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

  @doc "Runs the omit band: the staged row becomes its own golden."
  def new_golden!(candidate, staged, owner, tenant) do
    mapped = staged.mapped || %{}

    golden =
      AshEnterprise.Canonical.Person
      |> Ash.Changeset.for_create(
        :upsert_from_source,
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

    open_identity!(staged, candidate, golden.id, tenant)

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

  @doc "Survivorship: the golden's own values win; the staged values fill gaps."
  def fold!(staged, golden, tenant) do
    mapped = staged.mapped || %{}

    fills =
      %{
        "name" => golden.name && to_string(golden.name),
        "email" => golden.email && to_string(golden.email)
      }
      |> Enum.flat_map(fn {field, current} ->
        case {current, mapped[field]} do
          {nil, value} when is_binary(value) and value != "" -> [{field, value}]
          _ -> []
        end
      end)
      |> Map.new()

    unless map_size(fills) == 0 do
      golden
      |> Ash.Changeset.for_update(:mdm_survivor_update, fills, tenant: tenant, authorize?: false)
      |> Ash.update!(tenant: tenant, authorize?: false)
    end

    :ok
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
