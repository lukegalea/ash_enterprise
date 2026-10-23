defmodule AshEnterprise.Finance.Tiller.Step do
  @moduledoc """
  One sync step of a Tiller sheet: read both tabs, land what changed as new
  versions of the raw records, and record what each change means in the
  ledger. Run by `AshEnterprise.Finance.Tiller.Sync.run_step` as the human
  who owns the linked account.

  1. **Resolve the account** from the actor (`LinkedAccount.for_operation`,
     under the actor's own policies) and its sheet
     (`AshEnterprise.Finance.TillerSource`).
  2. **Admit** the account's zone tags into the finance zone (ADR 0042,
     `AshEnterprise.Finance.zone/0`) — on the land path, before anything is
     fetched.
  3. **Open the erasure scope** of the account (ADR 0024) and its keys for
     this step (`AshEnterprise.Finance.Sealing`). A shredded scope stops the
     step before any provider call.
  4. **Read** Transactions and Balance History through the adapter
     (`AshEnterprise.Finance.Tiller.Adapter`), and key each row
     (`AshEnterprise.Finance.Tiller.Rows`). A tab missing a header it needs
     stops the step: reading a reshuffled sheet as the old one would invent
     changes.
  5. **Compare** each row's keyed fingerprint with its record's current
     version. Unchanged rows land nothing. Each changed, new or vanished row
     is one `AshEnterprise.Finance.Recorder.apply_change/2`: a new version
     and its events, in one transaction.

  ## Re-running a sync appends nothing

  An unchanged row's fingerprint equals its current version's, so it is
  skipped: no raw version, no event. A version's events are also
  delivery-idempotent (kind + record + version instant), so even a version
  recorded twice records its events once.

  ## Removals are cautious

  A row is removed only by a step that read its whole tab, with no row it
  could not read (whose key it could not know), and a tab that comes back
  empty where rows had landed is an error (`:empty_tab`), never a removal of
  everything.

  ## Bounded

  At most `:max_changes` (default #{2_000}) rows land per step; a step that
  stops short reports `status: :more` (the worker continues promptly) and
  removes nothing. The first complete pass is the historical import (ADR
  0049): its events carry `context["import"] = true`, and the sheet's
  `imported_at` is set when it completes. Nothing is back-dated: the raw
  layer records when each row was observed, and each event's `occurred_at`
  carries the source's own truth time.

  ## No content leaves this module

  The summary is counts and reasons. Errors are reduced to structural
  reasons. Nothing here logs.
  """

  alias AshEnterprise.Finance
  alias AshEnterprise.Finance.{Recorder, Sealing, SourceRecord, TillerSource}
  alias AshEnterprise.Finance.Tiller.{Adapter, Rows, SyncError}
  alias AshEnterprise.Integration.{Landing, LinkedAccount}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Zones

  require Ash.Query

  @integration "google-sheet"
  @default_max_changes 2_000
  @streams [:transactions, :balance_history]

  @type summary :: %{
          status: :complete | :more,
          import: boolean(),
          rows: %{atom() => non_neg_integer()},
          unchanged: non_neg_integer(),
          landed: non_neg_integer(),
          removed: non_neg_integer(),
          events: %{atom() => non_neg_integer()},
          skipped: %{atom() => non_neg_integer()}
        }

  @doc "The Nango integration the vertical reads through."
  def integration, do: @integration

  @doc """
  Run one step for `linked_account_id` (nil: the actor's only Google Sheets
  account). Options: `:max_changes`, `:observed_at` (the step's observation
  instant; default now).
  """
  @spec run(term(), Ash.UUID.t() | nil, keyword()) :: {:ok, summary()} | {:error, term()}
  def run(actor, linked_account_id, opts \\ []) do
    run_id = AshEnterprise.Platform.Correlation.id()
    meta = [tenant: ActorContext.tenant(actor), linked_account_id: linked_account_id]
    lineage(:start, run_id, meta, [])

    case run_step(actor, linked_account_id, opts) do
      {:ok, _summary} = ok ->
        lineage(:complete, run_id, meta, [])
        ok

      {:error, error} = failed ->
        lineage(:fail, run_id, meta, reason: lineage_reason(error))
        failed
    end
  end

  @doc "The actor's own active Google Sheets account (`nil`: their only one)."
  @spec resolve_account(term(), Ash.UUID.t() | nil) :: {:ok, LinkedAccount.t()} | {:error, term()}
  def resolve_account(actor, linked_account_id) do
    case LinkedAccount.for_operation(@integration, linked_account_id,
           actor: actor,
           tenant: ActorContext.tenant(actor)
         ) do
      {:ok, [account]} -> {:ok, account}
      {:ok, []} -> {:error, edge_error(:no_linked_account)}
      {:ok, [_ | _]} -> {:error, edge_error(:ambiguous_linked_account)}
      {:error, error} -> {:error, error}
    end
  end

  defp run_step(actor, linked_account_id, opts) do
    observed_at = Keyword.get_lazy(opts, :observed_at, fn -> DateTime.utc_now() end)

    with {:ok, account} <- resolve_account(actor, linked_account_id),
         {:ok, source} <- sheet(actor, account),
         :ok <- admit(account),
         {:ok, keys} <- open_scope(account),
         {:ok, versions} <- versions(),
         {:ok, tabs} <- fetch(actor, account, source),
         {:ok, plan} <- plan(tabs, source, account, keys) do
      run = %{
        keys: keys,
        account: account,
        observed_at: observed_at,
        versions: versions,
        import?: is_nil(source.imported_at),
        region: Finance.region()
      }

      with {:ok, summary} <-
             execute(plan, run, Keyword.get(opts, :max_changes, @default_max_changes)) do
        finish(actor, source, summary, observed_at)
      end
    end
  end

  # --- before any provider call -----------------------------------------------------

  defp sheet(actor, account) do
    case TillerSource.for_linked_account(account.id,
           actor: actor,
           tenant: account.organization_id
         ) do
      {:ok, %TillerSource{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, SyncError.exception(reason: :no_sheet)}
      {:error, error} -> {:error, error}
    end
  end

  defp admit(account) do
    case Zones.admit(Finance.zone(), %{
           data_class: account.data_class,
           residency: account.residency
         }) do
      :ok ->
        :ok

      {:error, %Zones.Errors.Inadmissible{reason: reason}} ->
        {:error, SyncError.exception(reason: :zone_refused, detail: reason)}

      {:error, %Zones.Errors.UndeclaredZone{}} ->
        {:error, SyncError.exception(reason: :zone_refused, detail: :undeclared_zone)}
    end
  end

  defp open_scope(account) do
    with {:ok, scope} <- Landing.open(account),
         {:ok, keys} <- Sealing.open(scope) do
      {:ok, keys}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, SyncError.exception(reason: :landing_refused, detail: reason)}

      _other ->
        {:error, SyncError.exception(reason: :landing_refused, detail: :scope_unavailable)}
    end
  end

  defp versions do
    case Finance.active_versions() do
      {:ok, versions} -> {:ok, versions}
      {:error, _missing} -> {:error, SyncError.exception(reason: :mappings_not_installed)}
    end
  end

  # --- reading ----------------------------------------------------------------------

  defp fetch(actor, account, source) do
    conn = %{
      actor: actor,
      linked_account_id: account.id,
      spreadsheet_id: source.spreadsheet_id,
      ranges: %{transactions: source.transactions_range, balance_history: source.balances_range}
    }

    dsl = Finance.source()

    Enum.reduce_while(@streams, {:ok, %{}}, fn stream, {:ok, acc} ->
      case Adapter.fetch_batch(dsl, Finance.stream(stream), conn, nil, []) do
        {:ok, batch} -> {:cont, {:ok, Map.put(acc, stream, batch)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp plan(tabs, source, account, keys) do
    row_key = &Sealing.row_key(keys, &1)

    Enum.reduce_while(@streams, {:ok, %{}}, fn stream, {:ok, acc} ->
      %{headers: headers, records: rows} = Map.fetch!(tabs, stream)

      with {:ok, parsed} <- parse(stream, headers, rows, row_key),
           :ok <- currencies_declared(parsed, source),
           {:ok, current} <- current(account, stream),
           :ok <- not_emptied(parsed, current) do
        {:cont, {:ok, Map.put(acc, stream, %{parsed: parsed, current: current})}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, by_stream} -> {:ok, %{by_stream: by_stream, source: source}}
      error -> error
    end
  end

  defp parse(:transactions, headers, rows, row_key),
    do: layout(Rows.transactions(headers, rows, row_key), :transactions)

  defp parse(:balance_history, headers, rows, row_key),
    do: layout(Rows.balances(headers, rows, row_key), :balance_history)

  defp layout({:ok, parsed}, _stream), do: {:ok, parsed}

  defp layout({:error, {:unexpected_layout, _missing}}, stream),
    do: {:error, SyncError.exception(reason: :unexpected_layout, detail: stream)}

  defp currencies_declared(%{observations: observations}, source) do
    undeclared =
      observations
      |> Enum.reject(&TillerSource.currency_for(source, &1.account_ref))
      |> Enum.uniq_by(& &1.account_ref)
      |> length()

    if undeclared == 0,
      do: :ok,
      else: {:error, SyncError.exception(reason: :currency_undeclared, detail: undeclared)}
  end

  # The current version of every record this account has landed in the
  # stream: the structural columns and the payload envelope. Machinery read
  # (the raw layer has no person path).
  defp current(account, stream) do
    SourceRecord
    |> Ash.Query.filter(
      source == :tiller and stream == ^stream and
        source_metadata["linked_account_id"] == ^account.id
    )
    |> Ash.Query.select([:id, :external_id, :raw_payload, :valid_at])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, records} -> {:ok, Map.new(records, &{&1.external_id, &1})}
      {:error, _} -> {:error, SyncError.exception(reason: :record_failed, detail: :read)}
    end
  end

  defp not_emptied(%{observations: [], skipped: skipped}, current)
       when map_size(skipped) == 0 do
    if Enum.any?(current, fn {_id, record} -> present?(record) end),
      do: {:error, SyncError.exception(reason: :empty_tab)},
      else: :ok
  end

  defp not_emptied(_parsed, _current), do: :ok

  # --- landing ----------------------------------------------------------------------

  defp execute(plan, run, max_changes) do
    prefix = run.account.id <> ":"

    changes =
      Enum.map(@streams, fn stream ->
        %{parsed: parsed, current: current} = Map.fetch!(plan.by_stream, stream)
        {stream, diff(stream, parsed, current, prefix, plan.source, run.keys)}
      end)

    present_changes = Enum.flat_map(changes, fn {_stream, diff} -> diff.changes end)
    complete? = length(present_changes) <= max_changes

    removals =
      if complete?,
        do: Enum.flat_map(changes, fn {_stream, diff} -> diff.removals end),
        else: []

    to_apply = Enum.take(present_changes, max_changes) ++ removals

    with {:ok, events} <- apply_all(to_apply, run, plan.source) do
      {:ok,
       %{
         status: if(complete?, do: :complete, else: :more),
         import: run.import?,
         rows:
           Map.new(changes, fn {stream, _} ->
             {stream, length(plan.by_stream[stream].parsed.observations)}
           end),
         unchanged: Enum.sum(Enum.map(changes, fn {_s, d} -> d.unchanged end)),
         landed: min(length(present_changes), max_changes),
         removed: length(removals),
         events: events,
         skipped:
           Enum.reduce(changes, %{}, fn {_s, d}, acc ->
             Map.merge(acc, d.skipped, fn _k, a, b -> a + b end)
           end)
       }}
    end
  end

  # What changed in one stream: the rows to land (new or different), the
  # records to mark removed, and how many rows were unchanged.
  defp diff(stream, parsed, current, prefix, source, keys) do
    {changes, unchanged, seen} =
      Enum.reduce(parsed.observations, {[], 0, MapSet.new()}, fn observation,
                                                                 {changes, unchanged, seen} ->
        external_id = prefix <> observation.key
        fingerprint = Sealing.digest(keys, observation.row)
        seen = MapSet.put(seen, external_id)

        case Map.get(current, external_id) do
          %{raw_payload: %{"state" => "present", "fingerprint" => ^fingerprint}} ->
            {changes, unchanged + 1, seen}

          record ->
            change = %{
              stream: stream,
              external_id: external_id,
              row: observation.row,
              fingerprint: fingerprint,
              previous_record: record,
              account_ref: observation.account_ref
            }

            {[change | changes], unchanged, seen}
        end
      end)

    removals =
      if map_size(parsed.skipped) == 0 do
        current
        |> Enum.filter(fn {external_id, record} ->
          present?(record) and not MapSet.member?(seen, external_id)
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {external_id, record} ->
          %{
            stream: stream,
            external_id: external_id,
            row: nil,
            fingerprint: Sealing.digest(keys, %{"state" => "removed"}),
            previous_record: record,
            account_ref: nil
          }
        end)
      else
        []
      end

    _ = source

    %{
      changes: Enum.reverse(changes),
      removals: removals,
      unchanged: unchanged,
      skipped: parsed.skipped
    }
  end

  defp apply_all(changes, run, source) do
    Enum.reduce_while(changes, {:ok, %{}}, fn change, {:ok, counts} ->
      with {:ok, change} <- observe(change, run.keys, source),
           {:ok, kinds} <- record(run, change) do
        {:cont, {:ok, Enum.reduce(kinds, counts, &Map.update(&2, &1, 1, fn n -> n + 1 end))}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp record(run, change) do
    case Recorder.apply_change(run, change) do
      {:ok, kinds} ->
        {:ok, kinds}

      {:error, reason} when is_atom(reason) ->
        {:error, SyncError.exception(reason: :record_failed, detail: reason)}

      {:error, _ash_error} ->
        # An Ash error from a failed write can quote what it was writing.
        {:error, SyncError.exception(reason: :record_failed)}
    end
  end

  # The previous and current observations, normalized, with the account's
  # declared currency.
  defp observe(change, keys, source) do
    with {:ok, previous} <- previous(change.previous_record, keys, source),
         {:ok, current} <- normalized(change.stream, change.row, source) do
      {:ok,
       change
       |> Map.drop([:previous_record, :account_ref])
       |> Map.merge(%{previous: previous, current: current})}
    end
  end

  defp previous(nil, _keys, _source), do: {:ok, nil}

  defp previous(%{raw_payload: %{"state" => "removed"}}, _keys, _source), do: {:ok, :removed}

  defp previous(%{raw_payload: %{"sealed" => sealed}} = record, keys, source)
       when is_binary(sealed) do
    case Sealing.unseal(keys, sealed) do
      {:ok, row} -> normalized(stream_of(record), row, source)
      :error -> {:error, SyncError.exception(reason: :unreadable_record)}
    end
  end

  defp previous(_record, _keys, _source),
    do: {:error, SyncError.exception(reason: :unreadable_record)}

  defp stream_of(%{external_id: _} = record), do: Map.get(record, :stream, :transactions)

  defp normalized(_stream, nil, _source), do: {:ok, :removed}

  defp normalized(stream, row, source) do
    currency = TillerSource.currency_for(source, Rows.account_ref(row))

    result =
      case stream do
        :transactions -> Rows.normalize_transaction(row, currency)
        :balance_history -> Rows.normalize_balance(row, currency)
      end

    case result do
      {:ok, observation} ->
        {:ok, observation}

      {:error, reason} ->
        {:error, SyncError.exception(reason: :unreadable_record, detail: reason)}
    end
  end

  defp present?(%{raw_payload: %{"state" => "present"}}), do: true
  defp present?(_record), do: false

  # --- after ------------------------------------------------------------------------

  defp finish(actor, source, summary, observed_at) do
    attrs =
      %{last_synced_at: observed_at, last_summary: stringify(summary)}
      |> then(fn attrs ->
        if summary.status == :complete and is_nil(source.imported_at),
          do: Map.put(attrs, :imported_at, observed_at),
          else: attrs
      end)

    case TillerSource.record_run(source, attrs, actor: actor, tenant: source.organization_id) do
      {:ok, _source} -> {:ok, summary}
      {:error, error} -> {:error, error}
    end
  end

  defp stringify(summary) do
    Map.new(summary, fn
      {key, %{} = map} ->
        {Atom.to_string(key), Map.new(map, fn {k, v} -> {to_string(k), v} end)}

      {key, value} when is_atom(value) and not is_boolean(value) ->
        {Atom.to_string(key), Atom.to_string(value)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  # --- lineage and errors -----------------------------------------------------------

  # Job granularity (BIZEV-6): one run per step, structural names only.
  defp lineage(event, run_id, meta, extra) do
    AshEnterprise.Lineage.ingestion_event(
      event,
      "ingestion",
      "finance.tiller.sync",
      [
        run_id: run_id,
        inputs: ["tiller.sheet"],
        outputs: [AshEnterprise.Lineage.dataset(SourceRecord)]
      ] ++ meta ++ extra
    )
  end

  defp lineage_reason(error) do
    case {AshEnterprise.Integration.ProxyError.unwrap(error), SyncError.unwrap(error)} do
      {%{reason: reason}, _} -> to_string(reason)
      {nil, %SyncError{reason: reason}} -> to_string(reason)
      {nil, nil} -> "step_failed"
    end
  end

  defp edge_error(reason) do
    AshEnterprise.Integration.ProxyError.exception(reason: reason, integration: @integration)
  end
end
