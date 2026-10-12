defmodule AshEnterprise.Integration.Calendar.Step do
  @moduledoc """
  One bounded, resumable step of a linked account's calendar sync. Run by the
  `AshEnterprise.Integration.Calendar.Sync.run_step` action, as the human who
  owns the account.

  1. **Resolve the account** from the actor: `LinkedAccount.for_operation`
     under the actor's own policies, so the step can only ever sync an account
     its actor owns. (The provider actions resolve the connection again
     themselves; this step never sees it.)
  2. **Refresh the calendar list** (`calendarList.list`, all pages): a cursor
     per listed calendar is tracked, re-listed or un-listed.
  3. **Sync each listed calendar** with `events.list`, page by page, under a
     shared page budget (`:max_pages`). For each page: land every event under
     the account's scope, project it, then persist the cursor — so a step that
     dies mid-page re-fetches that page and re-lands it, and landing is an
     upsert on the source identity, so nothing duplicates.
       * `nextPageToken` → `SyncCursor.page`, continue.
       * `nextSyncToken` → `SyncCursor.complete`; the calendar is caught up.
       * **410 Gone** → `SyncCursor.reset` (the explicit sync-reset), then a
         full sync of that calendar, once per step.
       * 404 → the calendar is gone from under us: `SyncCursor.unlist`.
       * anything else stops the step with the edge's typed error.

  Requests always send `singleEvents=false` (recurring events as masters plus
  exceptions, so a full sync is bounded) and `showDeleted=true` (so a full sync
  after a reset still sees cancellations; incremental syncs include them
  regardless).

  ## Nothing lands by default

  `Landing.land/2` refuses every record until scoped landing is wired. The
  step checks for that before anything else and returns `SyncError`
  `:landing_refused`. It makes no provider call and writes no cursor row (a
  cursor holds a calendar id, which is often an email address). A lander
  that refuses a record later still stops the step before that record is
  projected or the cursor advances.

  The same preflight refuses with `:content_would_be_audited` while the
  projection would copy event content into the audit log in plaintext
  (`Projections.Calendar.audit_exposure/0`). The `:allow_audited_content?`
  option overrides it; only tests over synthetic data set it.

  ## Concurrent steps and resets

  The cursor writes are compare-and-set on what this step read (see
  `SyncCursor`, "Concurrent writers"). When one loses, because an operator
  reset or another step changed the cursor in the meantime, the step stops
  on that calendar, counts it in `:superseded`, and reports `status: :more`.
  The next step then starts from the cursor as it now stands. Anything the
  step already landed from that page stays landed. Landing is an upsert on
  the source identity, so the next pass re-lands it in place.

  ## No content leaves this module

  Errors are reduced to structural reasons before they are returned; the Ash
  error of a failed canonical write is dropped because it can carry the
  payload. Nothing here logs.
  """

  alias AshEnterprise.Canonical.Projections.Calendar, as: Projector
  alias AshEnterprise.Integration.Calendar.{SyncCursor, SyncError}

  alias AshEnterprise.Integration.{
    GoogleCalendar,
    Landing,
    LinkedAccount,
    ProxyError,
    SourceRecord
  }

  alias AshEnterprise.Security.ActorContext

  @integration "google-calendar"

  @default_page_size 250
  @default_max_pages 20
  @calendar_list_page_size 250
  @max_calendar_list_pages 10

  @type summary :: %{
          status: :complete | :more,
          calendars: non_neg_integer(),
          pages: non_neg_integer(),
          landed: non_neg_integer(),
          resets: non_neg_integer(),
          superseded: non_neg_integer(),
          projection: %{atom() => non_neg_integer()}
        }

  @doc "The Nango integration this vertical syncs."
  def integration, do: @integration

  @doc """
  Run one step for `linked_account_id` (nil: the actor's only Google Calendar
  account).

  Options (each defaulting to `config :ash_enterprise,
  AshEnterprise.Integration.Calendar`): `:page_size` (events per request,
  default #{@default_page_size}), `:max_pages` (events pages per step, default
  #{@default_max_pages}), `:project?` (default `true`),
  `:allow_audited_content?` (default `false`; see "Nothing lands by default").
  """
  @spec run(term(), Ash.UUID.t() | nil, keyword()) :: {:ok, summary()} | {:error, Exception.t()}
  def run(actor, linked_account_id, opts \\ []) do
    with {:ok, account} <- resolve_account(actor, linked_account_id) do
      state = init(actor, account, opts)

      with :ok <- preflight(state),
           {:ok, cursors} <- refresh_calendars(state) do
        sync(cursors, state)
      end
    end
  end

  # Refuse before the first provider call or cursor write, so a step that
  # cannot land or project leaves nothing behind (not even a cursor row, whose
  # calendar id is an email address).
  defp preflight(state) do
    cond do
      not landing_wired?() ->
        {:error, SyncError.exception(reason: :landing_refused, detail: :scoped_landing_not_wired)}

      state.project? and not Projector.audit_safe?(state.projection_context) ->
        {:error, SyncError.exception(reason: :content_would_be_audited)}

      true ->
        :ok
    end
  end

  # `Landing` keeps its lander private, so this reads the same config key and
  # treats the default as unwired. A `Landing.wired?/0` on the edge would
  # replace it.
  defp landing_wired? do
    lander =
      :ash_enterprise
      |> Application.get_env(Landing, [])
      |> Keyword.get(:lander, Landing.NotWired)

    lander != Landing.NotWired
  end

  @doc """
  The operator's explicit sync-reset: every cursor of the account forgets its
  tokens, so the next step full-syncs every calendar. Returns how many cursors
  were reset.
  """
  @spec reset(term(), Ash.UUID.t() | nil) :: {:ok, non_neg_integer()} | {:error, Exception.t()}
  def reset(actor, linked_account_id) do
    with {:ok, account} <- resolve_account(actor, linked_account_id),
         opts = cursor_opts(actor, account),
         {:ok, cursors} <- cursor_write(SyncCursor.for_account(account.id, opts)) do
      Enum.reduce_while(cursors, {:ok, 0}, &reset_one(&1, &2, opts))
    end
  end

  defp reset_one(cursor, {:ok, n}, opts) do
    case cursor_write(SyncCursor.reset(cursor, opts)) do
      {:ok, _} -> {:cont, {:ok, n + 1}}
      error -> {:halt, error}
    end
  end

  @doc """
  The actor's own active Google Calendar linked account, read under the
  actor's policies. Exposed for `Sync.request_sync`, which must refuse to
  enqueue for an account the actor does not own.
  """
  @spec resolve_account(term(), Ash.UUID.t() | nil) :: {:ok, struct()} | {:error, Exception.t()}
  def resolve_account(actor, linked_account_id) do
    actor_context = ActorContext.for_actor(actor)

    if is_nil(actor_context.user_id) or is_nil(actor_context.organization_id) do
      {:error, edge_error(:no_linked_account)}
    else
      case LinkedAccount.for_operation(@integration, linked_account_id,
             actor: actor,
             tenant: actor_context.organization_id
           ) do
        {:ok, [account]} -> {:ok, account}
        {:ok, []} -> {:error, edge_error(:no_linked_account)}
        {:ok, [_ | _]} -> {:error, edge_error(:ambiguous_linked_account)}
        {:error, error} -> {:error, error}
      end
    end
  end

  # --- state -------------------------------------------------------------------

  defp init(actor, account, opts) do
    actor_context = ActorContext.for_actor(actor)
    scope = Landing.scope(account)

    %{
      actor: actor,
      account: account,
      scope: scope,
      cursor_opts: cursor_opts(actor, account),
      page_size: option(opts, :page_size, @default_page_size),
      pages_left: option(opts, :max_pages, @default_max_pages),
      project?: option(opts, :project?, true),
      projection_context: %{
        owner_id: account.owner_id,
        tenant_id: account.organization_id,
        business_unit_id: actor_context.business_unit_id,
        actor: actor,
        scope: scope,
        allow_audited_content?: option(opts, :allow_audited_content?, false) == true
      },
      pages: 0,
      landed: 0,
      resets: 0,
      superseded: 0,
      more?: false,
      projection: %{projected: 0, cancelled: 0, cancelled_unrecorded: 0, skipped: 0}
    }
  end

  # Cursor bookkeeping runs in this trusted step, attributed to the actor: the
  # account's ownership was established by `resolve_account/2` under the
  # actor's policies, and the cursor's own grant is not what this step is for.
  defp cursor_opts(actor, account) do
    [actor: actor, tenant: account.organization_id, authorize?: false]
  end

  # --- the calendar list -------------------------------------------------------

  defp refresh_calendars(state) do
    with {:ok, listed_ids, complete?} <-
           list_calendar_ids(state, nil, [], @max_calendar_list_pages),
         {:ok, existing} <-
           cursor_write(SyncCursor.for_account(state.account.id, state.cursor_opts)),
         :ok <- reconcile(existing, listed_ids, complete?, state),
         {:ok, cursors} <-
           cursor_write(SyncCursor.for_account(state.account.id, state.cursor_opts)) do
      {:ok, Enum.filter(cursors, & &1.listed)}
    end
  end

  defp list_calendar_ids(state, page_token, acc, pages_left) do
    params =
      %{max_results: @calendar_list_page_size, linked_account_id: state.account.id}
      |> put_present(:page_token, page_token)

    with {:ok, body} <- GoogleCalendar.list_calendars(params, actor: state.actor) do
      acc = Enum.reverse(calendar_ids(body), acc)

      case {present(body["nextPageToken"]), pages_left > 1} do
        {nil, _} ->
          {:ok, acc |> Enum.reverse() |> Enum.uniq(), true}

        {token, true} ->
          list_calendar_ids(state, token, acc, pages_left - 1)

        {_token, false} ->
          # Truncated: sync what we saw, but un-list nothing on partial evidence.
          {:ok, acc |> Enum.reverse() |> Enum.uniq(), false}
      end
    end
  end

  defp calendar_ids(body) do
    body
    |> Map.get("items", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1["deleted"] == true))
    |> Enum.map(&present(&1["id"]))
    |> Enum.reject(&is_nil/1)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp reconcile(existing, listed_ids, complete?, state) do
    by_calendar = Map.new(existing, &{&1.calendar_id, &1})
    listed = MapSet.new(listed_ids)

    writes =
      Enum.flat_map(listed_ids, fn calendar_id ->
        case Map.fetch(by_calendar, calendar_id) do
          {:ok, %{listed: true}} -> []
          {:ok, cursor} -> [fn -> SyncCursor.relist(cursor, state.cursor_opts) end]
          :error -> [fn -> track(calendar_id, state) end]
        end
      end) ++
        for cursor <- existing,
            complete?,
            cursor.listed,
            not MapSet.member?(listed, cursor.calendar_id) do
          fn -> SyncCursor.unlist(cursor, state.cursor_opts) end
        end

    Enum.reduce_while(writes, :ok, fn write, :ok ->
      case cursor_write(write.()) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp track(calendar_id, state) do
    SyncCursor.track(
      %{linked_account_id: state.account.id, calendar_id: calendar_id},
      state.cursor_opts
    )
  end

  # --- events --------------------------------------------------------------------

  defp sync(cursors, state) do
    cursors
    |> Enum.reduce_while({:ok, state}, fn cursor, {:ok, state} ->
      case sync_calendar(cursor, state, false) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, summary(state, length(cursors))}
      error -> error
    end
  end

  defp sync_calendar(_cursor, %{pages_left: left} = state, _reset?) when left <= 0 do
    {:ok, %{state | more?: true}}
  end

  defp sync_calendar(cursor, state, reset?) do
    case fetch_page(cursor, state) do
      {:ok, body} ->
        state = %{state | pages: state.pages + 1, pages_left: state.pages_left - 1}

        with {:ok, state} <- land_page(body |> Map.get("items", []) |> List.wrap(), cursor, state) do
          advance(cursor, body, state, reset?)
        end

      {:error, error} ->
        recover(ProxyError.reason(error), error, cursor, state, reset?)
    end
  end

  # 410 Gone: the explicit reset, then a full sync of this calendar — once.
  defp recover(:gone, _error, cursor, state, false) do
    case guarded_write(SyncCursor.reset(cursor, read_as(cursor), state.cursor_opts)) do
      {:ok, cursor} -> sync_calendar(cursor, %{state | resets: state.resets + 1}, true)
      :superseded -> {:ok, superseded(state)}
      error -> error
    end
  end

  defp recover(:gone, _error, _cursor, _state, true) do
    {:error, SyncError.exception(reason: :repeated_gone)}
  end

  # 404: the calendar went away between the list and the events call.
  defp recover(:not_found, _error, cursor, state, _reset?) do
    with {:ok, _} <- cursor_write(SyncCursor.unlist(cursor, state.cursor_opts)) do
      {:ok, state}
    end
  end

  defp recover(_reason, error, _cursor, _state, _reset?), do: {:error, error}

  defp advance(cursor, body, state, reset?) do
    case body do
      %{"nextPageToken" => token} when is_binary(token) and token != "" ->
        case guarded_write(SyncCursor.page(cursor, token, read_as(cursor), state.cursor_opts)) do
          {:ok, cursor} -> sync_calendar(cursor, state, reset?)
          :superseded -> {:ok, superseded(state)}
          error -> error
        end

      %{"nextSyncToken" => token} when is_binary(token) and token != "" ->
        case guarded_write(SyncCursor.complete(cursor, token, read_as(cursor), state.cursor_opts)) do
          {:ok, _cursor} -> {:ok, state}
          :superseded -> {:ok, superseded(state)}
          error -> error
        end

      _ ->
        {:error, SyncError.exception(reason: :protocol)}
    end
  end

  # What this step read: the compare half of every compare-and-set cursor
  # write (`AshEnterprise.Integration.Calendar.Changes.CursorUnchanged`).
  defp read_as(cursor) do
    %{
      expected_sync_token: cursor.sync_token,
      expected_page_token: cursor.page_token,
      expected_reset_count: cursor.reset_count
    }
  end

  # The cursor moved on under this step: stop on this calendar and let the
  # next step start from the row as it now stands.
  defp superseded(state) do
    %{state | superseded: state.superseded + 1, more?: true}
  end

  defp fetch_page(cursor, state) do
    %{
      calendar_id: cursor.calendar_id,
      linked_account_id: state.account.id,
      max_results: state.page_size,
      single_events: false,
      show_deleted: true
    }
    |> put_present(:sync_token, cursor.sync_token)
    |> put_present(:page_token, cursor.page_token)
    |> GoogleCalendar.list_events(actor: state.actor)
  end

  defp land_page(items, cursor, state) do
    fetched_at = DateTime.utc_now()

    Enum.reduce_while(items, {:ok, state}, fn item, {:ok, state} ->
      case land_item(item, cursor, fetched_at, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp land_item(%{"id" => event_id} = item, cursor, fetched_at, state)
       when is_binary(event_id) and event_id != "" do
    record = %SourceRecord{
      external_system: Projector.external_system(),
      external_id:
        Projector.external_id(
          Projector.calendar_key(state.account.owner_id, cursor.calendar_id),
          event_id
        ),
      stream: Projector.stream(),
      raw_payload: item,
      cursor: nil,
      fetched_at: fetched_at,
      source_metadata: %{
        "calendar_cursor_id" => cursor.id,
        "linked_account_id" => state.account.id
      }
    }

    case Landing.land(record, scope: state.scope) do
      {:ok, _landed} ->
        project(record, %{state | landed: state.landed + 1})

      {:error, reason} ->
        {:error, SyncError.exception(reason: :landing_refused, detail: reason_atom(reason))}
    end
  end

  # An item without an id cannot be landed under any identity; it is counted,
  # not guessed at.
  defp land_item(_item, _cursor, _fetched_at, state) do
    {:ok, bump(state, :skipped)}
  end

  defp project(_record, %{project?: false} = state), do: {:ok, state}

  defp project(record, state) do
    case Projector.project(record, state.projection_context) do
      {:ok, %{outcome: outcome}} ->
        {:ok, bump(state, outcome)}

      {:error, :content_would_be_audited} ->
        {:error, SyncError.exception(reason: :content_would_be_audited)}

      {:error, _dropped_because_it_can_carry_the_payload} ->
        {:error, SyncError.exception(reason: :projection_failed)}
    end
  end

  defp bump(state, outcome) do
    %{state | projection: Map.update(state.projection, outcome, 1, &(&1 + 1))}
  end

  defp summary(state, calendars) do
    %{
      status: if(state.more?, do: :more, else: :complete),
      calendars: calendars,
      pages: state.pages,
      landed: state.landed,
      resets: state.resets,
      superseded: state.superseded,
      projection: state.projection
    }
  end

  # --- helpers -------------------------------------------------------------------

  defp cursor_write({:ok, _} = ok), do: ok
  defp cursor_write({:error, _}), do: {:error, SyncError.exception(reason: :cursor_write_failed)}

  defp guarded_write({:ok, _} = ok), do: ok

  defp guarded_write({:error, error} = result) do
    if stale?(error), do: :superseded, else: cursor_write(result)
  end

  defp stale?(%Ash.Error.Changes.StaleRecord{}), do: true
  defp stale?(%{errors: errors}) when is_list(errors), do: Enum.any?(errors, &stale?/1)
  defp stale?(_error), do: false

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom(_reason), do: :other

  defp edge_error(reason) do
    ProxyError.exception(reason: reason, integration: @integration)
  end

  defp option(opts, key, default) do
    Keyword.get_lazy(opts, key, fn ->
      :ash_enterprise
      |> Application.get_env(AshEnterprise.Integration.Calendar, [])
      |> Keyword.get(key, default)
    end)
  end
end
