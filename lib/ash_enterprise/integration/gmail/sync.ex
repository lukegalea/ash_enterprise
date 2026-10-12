defmodule AshEnterprise.Integration.Gmail.Sync do
  @moduledoc """
  One Gmail sync step for one linked account (epic E4): fetch through the
  edge's generated actions, land each message under the linked account's
  scope, and commit the cursor only after what it covers has landed.

      Sync.step(actor, linked_account_id)
      #=> {:ok, %{phase: :incremental, landed: 3, skipped: 0, more?: false, reset?: false}}
      #=> {:snooze, retry_after_ms} | {:cancel, reason} | {:error, reason}

  `actor` is the account's owner with an `ActorContext` attached; every call
  (the provider operations, the cursor reads and writes) runs as that human.
  The Nango connection is never named here: the edge resolves it from the
  actor's own linked account, narrowed by `linked_account_id`.

  ## The step

  Driven by `AshEnterprise.Integration.Gmail.SyncState.phase`:

    1. `:bootstrap` — `Gmail.get_profile` for the mailbox's current
       `historyId`, recorded *before* the backfill so that nothing arriving
       during it is missed.
    2. `:backfill` — `Gmail.list_messages` with `q: "newer_than:<N>d"`,
       capped at `backfill_max_messages`, one page at a time; each id fetched
       with `Gmail.get_message` and landed. The page token is the resume point.
       At the end the captured `historyId` becomes the incremental cursor.
    3. `:incremental` — `Gmail.list_history` (`messageAdded`) from the cursor;
       added messages fetched and landed; the cursor committed after every page
       (to the last history record's id, which is safe because
       `startHistoryId` is exclusive; to the response `historyId` on the last
       page).

  A 404 from `list_history` means Gmail no longer retains the cursor: the step
  calls the explicit `SyncState.reset_sync` (reason `:history_expired`) and
  falls back to a bounded resync (bootstrap + backfill) in the same step.

  A backfill resumed more than `backfill_window_days` after its `historyId`
  was captured is reset the same way (reason `:backfill_stale`): completing it
  would hand the incremental phase a cursor that replays everything since the
  capture, so the window and cap would bound nothing.

  A step does at most `max_pages_per_step` list pages; `more?: true` says it
  stopped on the budget, not on the end.

  ## What is never done

    * Nothing is logged here. Errors are reasons (atoms), never bodies.
    * A cursor is never advanced past a message that failed to land.
    * Nothing is fetched that could not be landed under the account's
      erasure scope (ADR 0024): the step opens the scope (`Landing.open/1`)
      before its first provider call, and stops with `{:cancel,
      :scoped_landing_not_wired}` or `{:cancel, :scope_shredded}` when it
      cannot. A shred racing the step refuses the next landing the same way.
    * Drafts (`DRAFT` label) are not landed: a draft is not a message anyone
      sent or received. A message deleted between listing and fetching (404)
      is skipped.

  ## Configuration

      config :ash_enterprise, AshEnterprise.Integration.Gmail.Sync,
        backfill_window_days: 7,
        backfill_max_messages: 200,
        page_size: 100,
        max_pages_per_step: 10,
        message_format: :full

  read with `Application.get_env/3`; `step/3`'s `opts` override it.
  """

  alias AshEnterprise.Integration.{Gmail, Landing, LinkedAccount, ProxyError, SourceRecord}
  alias AshEnterprise.Integration.Gmail.SyncState
  alias AshEnterprise.Security.ActorContext

  @integration "google-mail"
  @external_system "gmail"
  @stream "gmail.messages"

  @defaults [
    backfill_window_days: 7,
    backfill_max_messages: 200,
    page_size: 100,
    max_pages_per_step: 10,
    message_format: :full
  ]

  # Reasons that need a person (re-link, re-consent, configure) rather than a
  # retry. Retrying them only spends the provider's patience.
  @cancel_reasons [
    :unauthorized,
    :forbidden,
    :connection_not_found,
    :no_linked_account,
    :ambiguous_linked_account,
    :not_configured,
    :scoped_landing_not_wired,
    :scope_required,
    :scope_shredded,
    :cross_scope_landing
  ]

  @default_snooze_ms 60_000

  @type summary :: %{
          phase: :bootstrap | :backfill | :incremental,
          landed: non_neg_integer(),
          skipped: non_neg_integer(),
          more?: boolean(),
          reset?: boolean()
        }

  @type result ::
          {:ok, summary()}
          | {:snooze, pos_integer()}
          | {:cancel, atom()}
          | {:error, atom()}

  @doc "The landing stream every Gmail message lands on."
  def stream, do: @stream

  @doc "The `external_system` every Gmail message lands under."
  def external_system, do: @external_system

  @doc """
  The landed (and projected) identity of a Gmail object fetched through one
  linked account: `"<linked_account_id>:<gmail id>"`.

  Gmail message and thread ids are only unique within one mailbox, while every
  identity downstream (`SourceObject`'s `[external_system, external_id]`, the
  canonical `unique_external` per tenant) is wider than one mailbox. Without
  the account in the id, two mailboxes that happen to share an id would
  overwrite each other's row, scope and owner.
  """
  @spec external_id(Ash.UUID.t(), String.t()) :: String.t()
  def external_id(linked_account_id, gmail_id)
      when is_binary(linked_account_id) and is_binary(gmail_id),
      do: linked_account_id <> ":" <> gmail_id

  @doc """
  Run one sync step for one of `actor`'s own Gmail linked accounts.
  """
  @spec step(Ash.Resource.record(), Ash.UUID.t(), keyword()) :: result()
  def step(actor, linked_account_id, opts \\ []) do
    ctx = %{
      actor: actor,
      ash: [actor: actor, tenant: ActorContext.tenant(actor)],
      linked_account_id: linked_account_id,
      scope: nil,
      config: Keyword.merge(@defaults, Keyword.merge(config(), opts))
    }

    acc = %{
      phase: :bootstrap,
      landed: 0,
      skipped: 0,
      more?: false,
      reset?: false,
      pages_left: ctx.config[:max_pages_per_step]
    }

    with {:ok, account} <- resolve_account(ctx),
         {:ok, scope} <- Landing.open(account),
         ctx = %{ctx | scope: scope},
         {:ok, state} <- open_state(ctx) do
      state
      |> run(ctx, acc)
      |> finish()
    else
      {:error, reason} -> classify(reason)
    end
  end

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])

  # --- setup -------------------------------------------------------------------

  # The account must be one of the actor's own active Gmail links; a
  # deactivated or unlinked account stops the sync rather than erroring.
  defp resolve_account(ctx) do
    case LinkedAccount.for_operation(@integration, ctx.linked_account_id, ctx.ash) do
      {:ok, [account]} -> {:ok, account}
      {:ok, []} -> {:error, :no_linked_account}
      {:ok, _several} -> {:error, :ambiguous_linked_account}
      {:error, error} -> {:error, error}
    end
  end

  defp open_state(ctx) do
    case SyncState.for_linked_account(ctx.linked_account_id, ctx.ash) do
      {:ok, %SyncState{} = state} -> {:ok, state}
      {:ok, nil} -> SyncState.open(%{linked_account_id: ctx.linked_account_id}, ctx.ash)
      {:error, error} -> {:error, error}
    end
  end

  defp finish({:ok, state, acc}),
    do: {:ok, %{Map.drop(acc, [:pages_left]) | phase: state.phase}}

  defp finish({:error, reason}), do: classify(reason)

  # --- phases ------------------------------------------------------------------

  defp run(%SyncState{phase: :bootstrap} = state, ctx, acc) do
    with {:ok, profile} <- Gmail.get_profile(%{linked_account_id: ctx.linked_account_id}, ctx.ash),
         {:ok, history_id} <- history_id(profile),
         {:ok, state} <-
           advance(state, ctx, %{
             phase: :backfill,
             backfill_history_id: history_id,
             backfill_started_at: DateTime.utc_now(),
             backfill_page_token: nil,
             backfill_landed: 0
           }) do
      run(state, ctx, acc)
    end
  end

  defp run(%SyncState{phase: :backfill} = state, ctx, acc) do
    remaining = ctx.config[:backfill_max_messages] - state.backfill_landed

    cond do
      # The captured historyId becomes the incremental cursor, so resuming a
      # backfill that stalled (cancelled, landing not wired, account paused)
      # for longer than its window would replay every messageAdded since
      # then, whatever the window and cap say. Start a fresh bounded one.
      stale_backfill?(state, ctx) and not acc.reset? ->
        reset(state, ctx, acc, :backfill_stale)

      remaining <= 0 ->
        complete_backfill(state, ctx, acc)

      acc.pages_left <= 0 ->
        {:ok, state, %{acc | more?: true}}

      true ->
        backfill_page(state, ctx, acc, remaining)
    end
  end

  defp run(%SyncState{phase: :incremental} = state, ctx, acc) do
    incremental_page(state, ctx, acc, state.history_id, nil)
  end

  defp backfill_page(state, ctx, acc, remaining) do
    params =
      %{
        q: "newer_than:#{ctx.config[:backfill_window_days]}d",
        max_results: min(ctx.config[:page_size], remaining),
        linked_account_id: ctx.linked_account_id
      }
      |> put_present(:page_token, state.backfill_page_token)

    cursor = %{"phase" => "backfill", "historyId" => state.backfill_history_id}

    with {:ok, body} <- Gmail.list_messages(params, ctx.ash),
         ids = backfill_ids(body, remaining),
         {:ok, acc} <- fetch_and_land(ids, cursor, ctx, acc_page(acc)) do
      next_backfill_page(
        state,
        ctx,
        acc,
        present(body["nextPageToken"]),
        state.backfill_landed + length(ids)
      )
    end
  end

  defp backfill_ids(body, remaining) do
    body
    |> Map.get("messages")
    |> List.wrap()
    |> Enum.map(& &1["id"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(remaining)
  end

  defp next_backfill_page(state, ctx, acc, next, consumed) do
    if next && consumed < ctx.config[:backfill_max_messages] do
      with {:ok, state} <-
             advance(state, ctx, %{backfill_page_token: next, backfill_landed: consumed}) do
        run(state, ctx, acc)
      end
    else
      complete_backfill(%{state | backfill_landed: consumed}, ctx, acc)
    end
  end

  # The historyId captured before the backfill becomes the cursor.
  defp complete_backfill(state, ctx, acc) do
    with {:ok, state} <-
           advance(state, ctx, %{
             phase: :incremental,
             history_id: state.backfill_history_id,
             backfill_history_id: nil,
             backfill_started_at: nil,
             backfill_page_token: nil,
             backfill_landed: 0,
             last_synced_at: DateTime.utc_now()
           }) do
      run(state, ctx, acc)
    end
  end

  # `start` stays the request's startHistoryId across its pages (a page token
  # belongs to the request that issued it); the committed cursor moves on.
  defp incremental_page(state, _ctx, %{pages_left: left} = acc, _start, _page_token)
       when left <= 0,
       do: {:ok, state, %{acc | more?: true}}

  defp incremental_page(state, ctx, acc, start, page_token) do
    params =
      %{
        start_history_id: start,
        history_types: [:messageAdded],
        max_results: ctx.config[:page_size],
        linked_account_id: ctx.linked_account_id
      }
      |> put_present(:page_token, page_token)

    case Gmail.list_history(params, ctx.ash) do
      {:ok, body} -> incremental_landed(state, ctx, acc, start, body)
      {:error, error} -> history_failed(error, state, ctx, acc)
    end
  end

  # 404: Gmail no longer retains the cursor. Resync once per step.
  defp history_failed(error, state, ctx, acc) do
    if ProxyError.reason(error) == :not_found and not acc.reset?,
      do: resync(state, ctx, acc),
      else: {:error, error}
  end

  defp incremental_landed(state, ctx, acc, start, body) do
    records = body |> Map.get("history") |> List.wrap()

    ids =
      records
      |> Enum.flat_map(&List.wrap(&1["messagesAdded"]))
      |> Enum.map(&get_in(&1, ["message", "id"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    cursor = %{"phase" => "incremental", "startHistoryId" => start}
    next = present(body["nextPageToken"])

    with {:ok, acc} <- fetch_and_land(ids, cursor, ctx, acc_page(acc)),
         {:ok, state} <- advance(state, ctx, incremental_changes(state, body, records, next)) do
      if next,
        do: incremental_page(state, ctx, acc, start, next),
        else: {:ok, state, acc}
    end
  end

  # Mid-pass: the last history record's id (startHistoryId is exclusive). On
  # the last page: the response's historyId.
  defp incremental_changes(state, _body, records, next) when is_binary(next),
    do: %{history_id: last_record_id(records) || state.history_id}

  defp incremental_changes(state, body, records, nil) do
    %{
      history_id: stringify(body["historyId"]) || last_record_id(records) || state.history_id,
      last_synced_at: DateTime.utc_now()
    }
  end

  # Gmail no longer retains the cursor: an explicit reset, then a bounded
  # resync in the same step. A second 404 in one step is an error, not a loop.
  defp resync(state, ctx, acc), do: reset(state, ctx, acc, :history_expired)

  defp reset(state, ctx, acc, reason) do
    with {:ok, state} <- SyncState.reset_sync(state, %{reason: reason}, ctx.ash) do
      run(state, ctx, %{acc | reset?: true})
    end
  end

  # A backfill row without a capture time predates the column: treat it as
  # stale rather than trust a historyId of unknown age.
  defp stale_backfill?(%SyncState{backfill_started_at: nil}, _ctx), do: true

  defp stale_backfill?(%SyncState{backfill_started_at: started_at}, ctx) do
    window_seconds = ctx.config[:backfill_window_days] * 86_400
    DateTime.diff(DateTime.utc_now(), started_at, :second) > window_seconds
  end

  # --- fetch and land ----------------------------------------------------------

  defp fetch_and_land(ids, cursor, ctx, acc) do
    Enum.reduce_while(ids, {:ok, acc}, fn id, {:ok, acc} ->
      case fetch_message(id, ctx) do
        {:ok, :skip} -> {:cont, {:ok, %{acc | skipped: acc.skipped + 1}}}
        {:ok, message} -> land_message(id, message, cursor, ctx, acc)
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp land_message(id, message, cursor, ctx, acc) do
    case Landing.land(source_record(id, message, cursor, ctx), scope: ctx.scope) do
      {:ok, _landed} -> {:cont, {:ok, %{acc | landed: acc.landed + 1}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp fetch_message(id, ctx) do
    params = %{
      id: id,
      format: ctx.config[:message_format],
      linked_account_id: ctx.linked_account_id
    }

    case Gmail.get_message(params, ctx.ash) do
      {:ok, %{"labelIds" => labels} = message} when is_list(labels) ->
        if "DRAFT" in labels, do: {:ok, :skip}, else: {:ok, message}

      {:ok, %{} = message} ->
        {:ok, message}

      {:error, error} ->
        # Deleted between listing and fetching: nothing to land.
        if ProxyError.reason(error) == :not_found, do: {:ok, :skip}, else: {:error, error}
    end
  end

  # `id` is the id the step asked messages.get for (the one listing named).
  defp source_record(id, message, cursor, ctx) do
    %SourceRecord{
      external_system: @external_system,
      external_id: external_id(ctx.linked_account_id, id),
      stream: @stream,
      raw_payload: message,
      cursor: cursor,
      fetched_at: DateTime.utc_now(),
      source_metadata: %{
        "stream" => @stream,
        "thread_id" => message["threadId"],
        "linked_account_id" => ctx.linked_account_id
      }
    }
  end

  # --- helpers -----------------------------------------------------------------

  defp advance(state, ctx, changes), do: SyncState.advance(state, changes, ctx.ash)

  defp acc_page(acc), do: %{acc | pages_left: acc.pages_left - 1}

  defp history_id(%{"historyId" => id}) when is_binary(id) or is_integer(id),
    do: {:ok, stringify(id)}

  defp history_id(_profile), do: {:error, :provider_error}

  defp last_record_id(records) do
    records
    |> Enum.map(&stringify(&1["id"]))
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(_value), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp put_present(map, key, value) do
    case present(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  # --- outcomes ----------------------------------------------------------------

  defp classify(%Ash.Error.Forbidden{}), do: {:cancel, :forbidden}

  defp classify(reason) when is_atom(reason) and reason in @cancel_reasons,
    do: {:cancel, reason}

  defp classify(reason) when is_atom(reason), do: {:error, reason}

  defp classify(error) do
    case ProxyError.unwrap(error) do
      %ProxyError{reason: :rate_limited, retry_after_ms: ms} ->
        {:snooze, ms || @default_snooze_ms}

      %ProxyError{reason: reason} ->
        classify(reason)

      nil ->
        if forbidden?(error), do: {:cancel, :forbidden}, else: {:error, :unexpected}
    end
  end

  defp forbidden?(%Ash.Error.Forbidden{}), do: true
  defp forbidden?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &forbidden?/1)
  defp forbidden?(_error), do: false
end
