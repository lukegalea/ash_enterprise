defmodule AshEnterprise.Finance.Recorder do
  @moduledoc """
  Lands one changed Tiller row as a new version of its raw record and
  records the ledger events the change implies — in one transaction, under
  the ledger region's lock (`AshEnterprise.BusinessEvents.Recorder.locked/1`).

  Together or not at all, because the raw layer is what decides whether a
  row changed: a row that landed without its events would look unchanged
  on the next poll, and its events would never be recorded.

  ## An event

  The kind's active `AshEnterprise.Finance.MappingVersion` is applied to the
  observation payload (`AshEnterprise.Finance.Tiller.Derivation`), and the
  ledger row is:

    * `subject_type` `"tiller.transaction"` or `"tiller.balance"`,
      `subject_stream` `:tiller`, `subject_external_id` the raw record's
      external id (`"<linked account id>:<row key>"`);
    * `occurred_at` the mapping's extraction: the transaction's date (its
      `T00:00:00Z`, ADR 0049's date convention), a balance's date and time,
      a recategorization's or removal's instant;
    * `data` — the mapped fields **sealed** under the linked account's
      erasure scope (`"sealed"`), beside the structural ids a consumer needs
      to find it (`source_record_id`, `linked_account_id`,
      `erasure_scope_id`) and, for amounts, the `currency`;
    * `provenance` — the mapping version and the raw record;
    * `context` — the owner (the linked account's owner, who alone reads
      it), the tenant, and `"import" => true` during the first complete
      pass (the historical backfill);
    * `supersedes_event_id` — for a re-post or a changed balance, the last
      event of that kind about the subject (BIZEV-9);
    * `delivery_key` — derived from the kind, the raw record and the version
      instant, so recording a version's events twice records them once.

  Machinery, like the sync that calls it: `authorize?: false`. Who an event
  belongs to is its `context["owner"]`, never the caller.
  """

  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.Ledger
  alias AshEnterprise.Finance.{Sealing, SourceRecord}
  alias AshEnterprise.Finance.Tiller.Derivation

  @source :tiller

  @subject_types %{transactions: "tiller.transaction", balance_history: "tiller.balance"}

  @typedoc """
  What the step knows for the whole run: the keys, the account, the tenant
  and owner, the observation instant, the active mapping versions and
  whether this pass is the import.
  """
  @type run :: %{
          keys: Sealing.t(),
          account: struct(),
          observed_at: DateTime.t(),
          versions: %{atom() => struct()},
          import?: boolean(),
          region: atom()
        }

  @typedoc """
  One changed row: its stream and external id, the raw row (nil when it was
  removed), the fingerprint, and the previous and current normalized
  observations (`:removed`, or nil for first sight).
  """
  @type change :: %{
          stream: :transactions | :balance_history,
          external_id: String.t(),
          row: map() | nil,
          fingerprint: String.t(),
          previous: map() | :removed | nil,
          current: map() | :removed
        }

  @doc "Land one change and record its events. `{:ok, [kind]}` — the kinds recorded."
  @spec apply_change(run(), change()) :: {:ok, [atom()]} | {:error, term()}
  def apply_change(run, change) do
    BusinessEvents.Recorder.locked(fn ->
      with {:ok, record} <- land(run, change) do
        change
        |> events(run)
        |> Enum.reduce_while({:ok, []}, fn event, {:ok, kinds} ->
          case record_event(run, change, record, event) do
            {:ok, _row} -> {:cont, {:ok, [event.kind | kinds]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, kinds} -> {:ok, Enum.reverse(kinds)}
          error -> error
        end
      end
    end)
  end

  @doc "The raw payload a version lands with (see `AshEnterprise.Finance.SourceRecord`)."
  @spec raw_payload(Sealing.t(), map() | nil, String.t()) :: map()
  def raw_payload(_keys, nil, fingerprint),
    do: %{"v" => 1, "state" => "removed", "fingerprint" => fingerprint, "sealed" => nil}

  def raw_payload(keys, row, fingerprint),
    do: %{
      "v" => 1,
      "state" => "present",
      "fingerprint" => fingerprint,
      "sealed" => Sealing.seal(keys, row)
    }

  defp land(run, change) do
    SourceRecord.land(
      %{
        source: @source,
        stream: change.stream,
        external_id: change.external_id,
        region: run.region,
        residency_tag: Atom.to_string(run.region),
        raw_payload: raw_payload(run.keys, change.row, change.fingerprint),
        source_metadata: %{"linked_account_id" => run.account.id, "adapter" => "tiller"},
        cursor: nil,
        fetched_at: run.observed_at
      },
      authorize?: false
    )
  end

  defp events(%{stream: :transactions} = change, run),
    do: Derivation.transaction(change.previous, change.current, run.observed_at)

  defp events(%{stream: :balance_history} = change, _run),
    do: Derivation.balance(change.previous, change.current)

  defp record_event(run, change, record, event) do
    version = Map.fetch!(run.versions, event.kind)

    with {:ok, canonical} <- map(version, event.payload),
         {:ok, supersedes} <- supersedes(run, change, event) do
      %{
        event_kind: canonical.event_kind,
        region: BusinessEvents.region(),
        residency_tag: BusinessEvents.residency_tag(),
        subject_type: Map.fetch!(@subject_types, change.stream),
        subject_stream: @source,
        subject_external_id: change.external_id,
        occurred_at: canonical.occurred_at,
        data: data(run, record, event, canonical),
        provenance: Map.put(canonical.provenance, "source_record_id", record.id),
        delivery_key: delivery_key(event.kind, record.id, run.observed_at),
        context: context(run),
        supersedes_event_id: supersedes
      }
      |> Ledger.record(tenant: run.account.organization_id, authorize?: false)
    end
  end

  # The mapping is pure and its errors name operators and values; only the
  # structural fact that it failed leaves here.
  defp map(version, payload) do
    case AshDiscreteBusinessEvents.Mappings.run(version, payload) do
      {:ok, canonical} -> {:ok, canonical}
      {:ok, :skipped, _reason} -> {:error, :mapping_skipped}
      {:error, _detail} -> {:error, :mapping_failed}
    end
  end

  defp data(run, record, event, canonical) do
    %{
      "sealed" => Sealing.seal(run.keys, canonical.data),
      "source_record_id" => record.id,
      "linked_account_id" => run.account.id,
      "erasure_scope_id" => run.keys.scope_id
    }
    |> put_currency(event.payload["currency"])
  end

  defp put_currency(data, currency) when is_binary(currency),
    do: Map.put(data, "currency", currency)

  defp put_currency(data, _none), do: data

  defp context(run) do
    %{
      "owner" => %{
        "user_id" => run.account.owner_id,
        "business_unit_id" => run.account.owning_business_unit_id
      },
      "organization_id" => run.account.organization_id,
      "import" => run.import?
    }
  end

  defp supersedes(_run, _change, %{supersedes?: false}), do: {:ok, nil}

  defp supersedes(run, change, %{kind: kind}) do
    case Ledger.by_subject(BusinessEvents.region(), change.external_id, @source,
           tenant: run.account.organization_id,
           authorize?: false
         ) do
      {:ok, events} ->
        {:ok,
         events
         |> Enum.filter(&(&1.action == kind))
         |> List.last()
         |> case do
           nil -> nil
           event -> event.id
         end}

      {:error, _} = error ->
        error
    end
  end

  # Ids and an instant only, hashed so the key fits and says nothing.
  defp delivery_key(kind, record_id, observed_at) do
    digest =
      :sha256
      |> :crypto.hash(Enum.join([kind, record_id, DateTime.to_iso8601(observed_at)], <<0>>))
      |> Base.encode16(case: :lower)

    "finance:" <> digest
  end
end
