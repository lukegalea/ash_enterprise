defmodule AshEnterprise.BusinessEvents.Recorder do
  @moduledoc """
  Records the facts `AshEnterprise.BusinessEvents.Derivation` derives from a
  canonical row into `AshEnterprise.BusinessEvents.Ledger`, as that row's
  owner and in its tenant; and the tombstones a shred leaves.

  The one place that reads before deriving: a calendar event's last fact,
  and a conversation's current start (`Ledger.by_subject/4`), which the
  derivation diffs against. Everything else is the ledger's own `record` —
  locked, chained, delivery-idempotent.

  ## Read, decide, write — under the region's lock

  Each call takes the ledger region's advisory lock (the one `record` takes
  before every append, `RegionLockKeyGenerator.key_for/1`) before it reads,
  in a transaction that holds it until the facts are written. Two
  projections deriving about one subject therefore cannot both read the
  same predecessor: the second reads what the first recorded. Without it, two
  messages of one conversation projected at once could both find no start,
  the earlier one's start would collapse onto the later one's delivery key,
  and the conversation would keep the later start. Inside a projection's
  transaction the lock is held until that transaction ends, which is where
  `record` would hold it anyway.

  Recording is machinery, like the projection that triggers it, so it runs
  with `authorize?: false`; who a fact belongs to is its `context["owner"]`
  (`AshEnterprise.BusinessEvents.Changes.StampOwner`), never the caller.
  """

  alias AshDiscreteBusinessEvents.Ledger.RegionLockKeyGenerator
  alias AshDiscreteBusinessEvents.Retention
  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.{Derivation, Ledger}
  alias AshEnterprise.Canonical.Conversation
  alias AshEnterprise.Repo

  require Ash.Query

  @doc "Record what a calendar event's current state implies."
  @spec calendar_event(map()) :: {:ok, [Ash.Resource.record()]} | {:error, term()}
  def calendar_event(event) do
    locked(fn ->
      with {:ok, last} <- last_fact(event, "calendar_event", nil) do
        event
        |> Derivation.calendar_event(last)
        |> record_all(event)
      end
    end)
  end

  @doc """
  Record what a message implies: received or sent, and its conversation's
  start — or a correction of that start, when this message was sent before
  it.
  """
  @spec message(map()) :: {:ok, [Ash.Resource.record()]} | {:error, term()}
  def message(message) do
    locked(fn ->
      with {:ok, conversation} <- conversation(message),
           {:ok, current_start} <- current_start(conversation, message.organization_id) do
        message
        |> Derivation.message(conversation, current_start)
        |> record_all(message)
      end
    end)
  end

  @doc """
  Record the tombstones a shred of `scope` leaves: one
  `:"retention.subject_erased"` fact for each owner holding facts that point
  at the scope (`data.erasure_scope_id`), in that owner's tenant and stream,
  carrying how many of their facts it covers. An owner with no such facts
  gets none; a scope nothing was derived from leaves none (its own row is
  the audited record of the shred). Idempotent per scope and owner.

  The tombstone is the package's (`AshDiscreteBusinessEvents.Retention.tombstone/5`),
  so it reads as the same fact a package-run erasure records.
  """
  @spec shredded(map()) :: {:ok, [Ash.Resource.record()]} | {:error, term()}
  def shredded(scope) do
    region = BusinessEvents.region()

    locked(fn ->
      scope.id
      |> holders(region)
      |> record_each(fn {owner, held} -> record_tombstone(scope, owner, held, region) end)
    end)
  end

  defp record_tombstone(scope, owner, held, region) do
    tombstone = Derivation.shredded(scope, owner, held, region)

    :"retention.subject_erased"
    |> Retention.tombstone(region, tombstone.subject_external_id, tombstone.data,
      residency_tag: BusinessEvents.residency_tag(),
      occurred_at: tombstone.occurred_at,
      delivery_key: tombstone.delivery_key,
      context: context(owner)
    )
    |> Ledger.record(tenant: owner.organization_id, authorize?: false)
  end

  # Every owner holding facts that point at the scope, with how many. Across
  # tenants (platform tenancy is `global?`), one region, the derived facts
  # only: an earlier tombstone also names the scope and is not counted.
  defp holders(scope_id, region) do
    Ledger
    |> Ash.Query.for_read(:by_region, %{region: region}, authorize?: false)
    |> Ash.Query.filter(data["erasure_scope_id"] == ^scope_id and subject_type != "retention")
    |> Ash.Query.select([:id, :organization_id, :owner_id, :owning_business_unit_id])
    |> Ash.read!()
    |> Enum.frequencies_by(&Map.take(&1, [:organization_id, :owner_id, :owning_business_unit_id]))
    |> Enum.sort_by(fn {owner, _held} -> {owner.organization_id, owner.owner_id} end)
  end

  defp record_all(facts, row), do: record_each(facts, &record(&1, row))

  # Records each in turn; the first error stops it.
  defp record_each(items, record) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} -> collect(record.(item), acc) end)
    |> case do
      {:ok, recorded} -> {:ok, Enum.reverse(recorded)}
      error -> error
    end
  end

  defp collect({:ok, recorded}, acc), do: {:cont, {:ok, [recorded | acc]}}
  defp collect({:error, _} = error, _acc), do: {:halt, error}

  defp record(fact, row) do
    fact
    |> Map.merge(%{
      region: BusinessEvents.region(),
      residency_tag: BusinessEvents.residency_tag(),
      context: context(row)
    })
    |> Ledger.record(tenant: row.organization_id, authorize?: false)
  end

  defp context(row) do
    %{
      "owner" => %{
        "user_id" => row.owner_id,
        "business_unit_id" => row.owning_business_unit_id
      },
      "organization_id" => row.organization_id
    }
  end

  # The last fact of `subject_type` about the row's source identity, or nil.
  defp last_fact(row, subject_type, kind) do
    with {:ok, stream} <- Map.fetch(Derivation.streams(), row.external_system),
         true <- is_binary(row.external_id) do
      case Ledger.by_subject(BusinessEvents.region(), row.external_id, stream,
             tenant: row.organization_id,
             authorize?: false
           ) do
        {:ok, facts} ->
          {:ok,
           facts
           |> Enum.filter(
             &(&1.subject_type == subject_type and (is_nil(kind) or &1.action == kind))
           )
           |> List.last()}

        {:error, _} = error ->
          error
      end
    else
      _not_derivable -> {:ok, nil}
    end
  end

  # The conversation's latest start: by_subject is in sequence order, and a
  # correction is always recorded after what it supersedes, so the last
  # start is the current one.
  defp current_start(nil, _tenant), do: {:ok, nil}

  defp current_start(conversation, tenant) do
    conversation
    |> Map.put(:organization_id, tenant)
    |> last_fact("conversation", :"conversation.started")
  end

  defp conversation(%{conversation_id: nil}), do: {:ok, nil}

  defp conversation(%{conversation_id: id, organization_id: tenant}) do
    Conversation
    |> Ash.Query.for_read(:read, %{}, tenant: tenant, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :external_system, :external_id, :kind, :erasure_scope_id])
    |> Ash.read_one()
  end

  @doc """
  Run `fun` (returning `{:ok, result}` or `{:error, reason}`) in one
  transaction holding the ledger region's advisory lock, so a
  read-decide-write about a subject cannot interleave with another. Joins
  the caller's transaction when there is one. Used by the finance store's
  recorder too (`AshEnterprise.Finance.Recorder`), which lands its raw row
  and records its facts in the same transaction.
  """
  @spec locked((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  # Raw SQL by design: an advisory lock is not a domain read or write, and
  # this is the same statement, with the same key, the ledger's own append
  # takes (`AshDiscreteBusinessEvents.Ledger.Changes.StampEvent`).
  def locked(fun) do
    Repo.transaction(fn ->
      [namespace, key] = RegionLockKeyGenerator.key_for(BusinessEvents.region())
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1, $2)", [namespace, key])

      case fun.() do
        {:ok, result} -> result
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end
end
