defmodule AshEnterprise.Integration.Slack.Syncer do
  @moduledoc """
  One incremental Slack sync step for one linked account, run **as the human
  who owns it** (epic E4, Slack vertical; poll-only per ADR 0011's v1
  deviation — no Events API, no inbound endpoint).

  A step:

    1. **Refuses before any request** unless scoped landing is wired
       (`AshEnterprise.Integration.Landing`'s `:lander` is not the default
       `NotWired`): nothing is fetched that could not be landed under a shred
       scope.
    2. Resolves the linked account under the actor's own policies
       (`LinkedAccount.for_operation`); the connection is never an input.
    3. `conversations.list` (public and private channels, MPIMs, IMs), keeping
       only conversations the user is a member of; lands each as
       `slack.conversations`.
    4. For each conversation, `conversations.history` from its stored cursor
       (`ConversationCursor`), cursor-paginated, landing each message as
       `slack.messages` and saving the position after every page.
    5. Notes every message author (and IM counterpart) as a `KnownMember`,
       then `users.info` for the members that are due — never fetched, or not
       within the refresh interval; lands each as `slack.users`.

  Every record is landed with `Landing.land(record, scope: Landing.scope(id))`
  — one scope per linked account, so shredding that scope removes exactly that
  account's Slack data (`AshEnterprise.Integration.Slack.Records` explains the
  ids that make it exact).

  ## Budgets

  A step is bounded (`max_pages_per_step` history pages in total, at most
  `max_pages_per_conversation` per conversation, `max_user_lookups_per_step`
  profiles) and reports `more?: true` when it stopped on a budget, which the
  worker turns into a short snooze. The per-conversation cap is what keeps a
  first backfill of one busy channel from starving the others.

  The defaults sit inside Slack's tiers for an internal app: 40 history pages
  per step against `conversations.history`'s Tier 3 (~50/min), 20 list pages
  against `conversations.list`'s Tier 2 (~20/min), 50 profiles against
  `users.info`'s Tier 4 (~100/min). Going over is not fatal — a 429 comes back
  as a snooze — it is just slower.

  The first pass of a conversation reaches back `backfill_days` (default 30;
  `nil` means the whole history).

  ## Outcomes

    * `{:ok, summary}` — counts only.
    * `{:snooze, seconds}` — Slack rate-limited us past the edge's own retries
      (`:rate_limited`, `retry_after_ms`). Progress up to there is saved.
    * `{:cancel, reason}` — retrying cannot help: the account needs re-linking
      or a new consent, the actor lacks a grant, or landing is not wired.
    * `{:error, reason}` — transient; Oban retries with backoff.

  Per-conversation failures do not stop the step: an `invalid_cursor` page
  (`:gone`) triggers the explicit `ConversationCursor.reset_pass`, and a
  conversation Slack no longer shows us (`channel_not_found`,
  `not_in_channel`) is skipped.

  ## What never leaves the step

  Message text, names, emails and channel names are handed to the lander and
  nowhere else: logs, telemetry, lineage facets, job results and the cursor
  rows carry counts, ids, `ts` values and reason atoms only. A lander's error
  is reduced to `:landing_failed` for the same reason — its details could
  quote the payload.

  ## Configuration

      config :ash_enterprise, AshEnterprise.Integration.Slack.Syncer,
        list_limit: 200, max_list_pages: 20, history_limit: 200,
        max_pages_per_step: 40, max_pages_per_conversation: 5,
        max_user_lookups_per_step: 50, member_refresh_after_seconds: 604_800,
        backfill_days: 30, rate_limit_snooze_seconds: 60

  Any key may also be passed to `step/3` (tests do), as may `now:`.

  ## v1 limits

  Thread replies are not fetched (`conversations.replies` is not a declared
  operation); a reply appears only when broadcast to the channel. Edits and
  deletions of messages older than the high-water mark are not seen — polling
  `conversations.history` forward cannot see them, and the Events API is out of
  scope for v1.
  """

  alias AshEnterprise.Integration.{Landing, LinkedAccount, ProxyError, Slack}
  alias AshEnterprise.Integration.Slack.{ConversationCursor, KnownMember, Records}
  alias AshEnterprise.Security.ActorContext

  require Logger

  @integration "slack"
  @conversation_types "public_channel,private_channel,mpim,im"

  @defaults [
    list_limit: 200,
    max_list_pages: 20,
    history_limit: 200,
    max_pages_per_step: 40,
    max_pages_per_conversation: 5,
    max_user_lookups_per_step: 50,
    member_refresh_after_seconds: 7 * 24 * 60 * 60,
    backfill_days: 30,
    rate_limit_snooze_seconds: 60
  ]

  # Reasons retrying cannot fix: the account needs re-linking or a new consent,
  # the actor lacks a grant, the edge or landing is not configured, or the
  # request itself is wrong.
  @terminal [
    :unauthorized,
    :forbidden,
    :no_linked_account,
    :ambiguous_linked_account,
    :connection_not_found,
    :bad_request,
    :not_configured,
    :policy_forbidden,
    :scoped_landing_not_wired
  ]

  @lineage_job "slack.sync"
  @lineage_inputs ["slack.source"]
  @lineage_outputs ["slack.ingestion_source_objects"]

  @type summary :: %{
          conversations: non_neg_integer(),
          messages: non_neg_integer(),
          users: non_neg_integer(),
          resets: non_neg_integer(),
          skipped: non_neg_integer(),
          more?: boolean()
        }

  @type outcome ::
          {:ok, summary()} | {:snooze, pos_integer()} | {:cancel, atom()} | {:error, atom()}

  @doc """
  Run one sync step for `linked_account_id` (or, when nil, the actor's only
  active Slack account) as `actor` — a user carrying its `ActorContext`.
  """
  @spec step(struct(), Ash.UUID.t() | nil, keyword()) :: outcome()
  def step(actor, linked_account_id, opts \\ []) do
    run_id = AshEnterprise.Platform.Correlation.id()
    lineage(:start, run_id, [])

    state = initial_state(actor, opts)

    result =
      with {:ok, state} <- require_landing(state),
           {:ok, state} <- resolve_account(state, linked_account_id),
           state = load_noted(state),
           {:ok, conversations, state} <- list_conversations(state),
           {:ok, state} <- land_conversations(conversations, state),
           {:ok, state} <- sync_conversations(conversations, state) do
        sync_members(state)
      end

    finish(result, run_id)
  end

  # --- state -------------------------------------------------------------------

  defp initial_state(actor, opts) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:ash_enterprise, __MODULE__, []))
      |> Keyword.merge(Keyword.take(opts, Keyword.keys(@defaults)))
      |> Map.new()

    %{
      actor: actor,
      config: config,
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      linked_account_id: nil,
      scope: nil,
      budget: config.max_pages_per_step,
      noted: MapSet.new(),
      more?: false,
      counts: %{conversations: 0, messages: 0, users: 0, resets: 0, skipped: 0}
    }
  end

  defp bump(state, key, by \\ 1), do: update_in(state, [:counts, key], &(&1 + by))

  # --- 1. landing must be wired --------------------------------------------------

  # Read-only peek at the edge's landing config: a step that cannot land under
  # a scope must not fetch content in the first place.
  defp require_landing(state) do
    lander =
      :ash_enterprise
      |> Application.get_env(Landing, [])
      |> Keyword.get(:lander, Landing.NotWired)

    if lander == Landing.NotWired do
      {:stop, {:cancel, :scoped_landing_not_wired}, state}
    else
      {:ok, state}
    end
  end

  # --- 2. the linked account, under the actor's policies ------------------------

  defp resolve_account(state, linked_account_id) do
    case ActorContext.tenant(state.actor) do
      nil ->
        {:stop, {:cancel, :no_linked_account}, state}

      tenant ->
        case LinkedAccount.for_operation(@integration, linked_account_id,
               actor: state.actor,
               tenant: tenant
             ) do
          {:ok, [account]} ->
            {:ok, %{state | linked_account_id: account.id, scope: Landing.scope(account)}}

          {:ok, []} ->
            {:stop, {:cancel, :no_linked_account}, state}

          {:ok, [_ | _]} ->
            {:stop, {:cancel, :ambiguous_linked_account}, state}

          {:error, %Ash.Error.Forbidden{}} ->
            {:stop, {:cancel, :policy_forbidden}, state}

          {:error, _} ->
            {:stop, {:error, :linked_account_lookup_failed}, state}
        end
    end
  end

  # --- 3. conversations ------------------------------------------------------------

  defp list_conversations(state), do: list_conversations(state, nil, [], 0)

  defp list_conversations(state, cursor, acc, pages) do
    params =
      compact(%{
        types: @conversation_types,
        exclude_archived: true,
        limit: state.config.list_limit,
        cursor: cursor
      })

    case call(state, :list_conversations, params) do
      {:ok, body} ->
        acc = acc ++ Enum.filter(List.wrap(body["channels"]), &Records.member?/1)
        next = next_cursor(body)

        if next && pages + 1 < state.config.max_list_pages do
          list_conversations(state, next, acc, pages + 1)
        else
          {:ok, acc |> Enum.uniq_by(& &1["id"]) |> Enum.sort_by(& &1["id"]), state}
        end

      {:error, failure} ->
        {:stop, outcome(failure, state), state}
    end
  end

  defp land_conversations(conversations, state) do
    Enum.reduce_while(conversations, {:ok, state}, fn conversation, {:ok, state} ->
      record = Records.conversation(state.linked_account_id, conversation, state.now)

      case land(record, state) do
        :ok ->
          state =
            state
            |> bump(:conversations)
            |> add_authors(Records.author_ids([conversation]))

          {:cont, {:ok, state}}

        {:stop, _, _} = stop ->
          {:halt, stop}
      end
    end)
  end

  # --- 4. history ------------------------------------------------------------------

  defp sync_conversations(conversations, state) do
    cursors =
      state.linked_account_id
      |> ConversationCursor.for_account!(authorize?: false)
      |> Map.new(&{&1.channel_id, &1})

    Enum.reduce_while(conversations, {:ok, state}, fn %{"id" => channel}, {:ok, state} ->
      if state.budget <= 0 do
        {:halt, {:ok, %{state | more?: true}}}
      else
        case sync_conversation(channel, Map.get(cursors, channel), state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:stop, _, _} = stop -> {:halt, stop}
        end
      end
    end)
  end

  defp sync_conversation(channel, cursor, state) do
    pass =
      case cursor do
        %{page_cursor: page} when is_binary(page) ->
          %{oldest: cursor.pass_oldest, page: page, pass_latest: cursor.pass_latest_ts}

        %{latest_ts: latest} when is_binary(latest) ->
          %{oldest: latest, page: nil, pass_latest: nil}

        _ ->
          %{oldest: backfill_floor(state), page: nil, pass_latest: nil}
      end

    pass = Map.merge(pass, %{record: cursor, latest_ts: cursor && cursor.latest_ts, pages: 0})

    fetch_pages(channel, pass, state)
  end

  defp fetch_pages(channel, pass, state) do
    cond do
      state.budget <= 0 ->
        {:ok, %{state | more?: true}}

      pass.pages >= state.config.max_pages_per_conversation ->
        {:ok, %{state | more?: true}}

      true ->
        params =
          compact(%{
            channel: channel,
            oldest: pass.oldest,
            cursor: pass.page,
            limit: state.config.history_limit
          })

        case call(state, :conversation_history, params) do
          {:ok, body} -> landed_page(channel, pass, body, state)
          {:error, failure} -> history_failure(channel, pass, failure, state)
        end
    end
  end

  defp landed_page(channel, pass, body, state) do
    messages = body |> Map.get("messages") |> List.wrap() |> Enum.filter(&Records.ts?(&1["ts"]))

    with {:ok, state} <- land_messages(channel, messages, pass.oldest, state) do
      pass_latest = Enum.reduce(messages, pass.pass_latest, &Records.max_ts(&2, &1["ts"]))

      state =
        %{state | budget: state.budget - 1}
        |> add_authors(Records.author_ids(messages))

      case {body["has_more"], next_cursor(body)} do
        {true, next} when is_binary(next) ->
          record =
            save_position!(state, channel, %{
              latest_ts: pass.latest_ts,
              pass_oldest: pass.oldest,
              page_cursor: next,
              pass_latest_ts: pass_latest,
              synced_at: pass.record && pass.record.synced_at
            })

          fetch_pages(
            channel,
            %{pass | page: next, pass_latest: pass_latest, pages: pass.pages + 1, record: record},
            state
          )

        _ ->
          save_position!(state, channel, %{
            latest_ts: Records.max_ts(pass.latest_ts, pass_latest),
            pass_oldest: nil,
            page_cursor: nil,
            pass_latest_ts: nil,
            synced_at: state.now
          })

          {:ok, state}
      end
    end
  end

  # Slack refused the page cursor: the explicit sync-reset, never a silent
  # rewind. The next step starts a fresh pass from the high-water mark.
  defp history_failure(_channel, %{page: page, record: record}, %{reason: :gone}, state)
       when is_binary(page) and is_struct(record, ConversationCursor) do
    ConversationCursor.reset_pass!(record, authorize?: false)
    {:ok, bump(state, :resets)}
  end

  # The conversation is gone, or we are no longer in it: skip it this step.
  defp history_failure(_channel, _pass, %{reason: :not_found}, state),
    do: {:ok, bump(state, :skipped)}

  defp history_failure(_channel, _pass, %{reason: :forbidden, code: "not_in_channel"}, state),
    do: {:ok, bump(state, :skipped)}

  defp history_failure(_channel, _pass, failure, state),
    do: {:stop, outcome(failure, state), state}

  defp land_messages(channel, messages, oldest, state) do
    cursor = %{"oldest" => oldest}

    Enum.reduce_while(messages, {:ok, state}, fn message, {:ok, state} ->
      record = Records.message(state.linked_account_id, channel, message, cursor, state.now)

      case land(record, state) do
        :ok -> {:cont, {:ok, bump(state, :messages)}}
        {:stop, _, _} = stop -> {:halt, stop}
      end
    end)
  end

  defp save_position!(state, channel, position) do
    position
    |> Map.merge(%{linked_account_id: state.linked_account_id, channel_id: channel})
    |> ConversationCursor.save!(authorize?: false)
  end

  defp backfill_floor(%{config: %{backfill_days: nil}}), do: nil

  defp backfill_floor(%{config: %{backfill_days: days}, now: now}) when is_integer(days) do
    now |> DateTime.add(-days * 24 * 60 * 60, :second) |> Records.datetime_to_ts()
  end

  # --- 5. members ------------------------------------------------------------------

  defp sync_members(state) do
    stale_before = DateTime.add(state.now, -state.config.member_refresh_after_seconds, :second)
    limit = state.config.max_user_lookups_per_step

    due =
      KnownMember.due!(state.linked_account_id, stale_before,
        authorize?: false,
        query: [limit: limit + 1]
      )

    {batch, rest} = due |> Enum.map(& &1.slack_user_id) |> Enum.split(limit)
    state = if rest == [], do: state, else: %{state | more?: true}

    Enum.reduce_while(batch, {:ok, state}, fn user_id, {:ok, state} ->
      case fetch_member(user_id, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, _, _} = stop -> {:halt, stop}
      end
    end)
  end

  defp fetch_member(user_id, state) do
    case call(state, :user_info, %{user: user_id}) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        record = Records.user(state.linked_account_id, user, state.now)

        case land(record, state) do
          :ok ->
            mark_fetched!(state, user_id)
            {:ok, bump(state, :users)}

          stop ->
            stop
        end

      {:ok, _malformed} ->
        {:stop, {:error, :provider_error}, state}

      # A deleted or invisible member: remember the attempt so it is not
      # re-spent every step until the refresh interval passes.
      {:error, %{reason: :not_found}} ->
        mark_fetched!(state, user_id)
        {:ok, bump(state, :skipped)}

      {:error, failure} ->
        {:stop, outcome(failure, state), state}
    end
  end

  defp mark_fetched!(state, user_id) do
    KnownMember.mark_fetched!(
      %{
        linked_account_id: state.linked_account_id,
        slack_user_id: user_id,
        fetched_at: state.now
      },
      authorize?: false
    )
  end

  defp load_noted(state) do
    noted =
      state.linked_account_id
      |> KnownMember.for_account!(authorize?: false)
      |> MapSet.new(& &1.slack_user_id)

    %{state | noted: noted}
  end

  # Members are noted as soon as the page that mentions them has landed, so a
  # step that stops later (budget, rate limit, crash) still leaves them due.
  defp add_authors(state, ids) do
    ids
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(state.noted, &1))
    |> Enum.reduce(state, fn user_id, state ->
      KnownMember.note_seen!(
        %{linked_account_id: state.linked_account_id, slack_user_id: user_id},
        authorize?: false
      )

      %{state | noted: MapSet.put(state.noted, user_id)}
    end)
  end

  # --- the edge, and the landing seam ----------------------------------------------

  defp call(state, operation, params) do
    params = Map.put(params, :linked_account_id, state.linked_account_id)

    result =
      case operation do
        :list_conversations -> Slack.list_conversations(params, actor: state.actor)
        :conversation_history -> Slack.conversation_history(params, actor: state.actor)
        :user_info -> Slack.user_info(params, actor: state.actor)
      end

    case result do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _} -> {:error, %{reason: :provider_error, code: nil, retry_after_ms: nil}}
      {:error, error} -> {:error, failure(error)}
    end
  end

  defp failure(error) do
    case ProxyError.unwrap(error) do
      %ProxyError{} = proxy ->
        %{reason: proxy.reason, code: proxy.provider_code, retry_after_ms: proxy.retry_after_ms}

      nil ->
        reason = if match?(%Ash.Error.Forbidden{}, error), do: :policy_forbidden, else: :unknown
        %{reason: reason, code: nil, retry_after_ms: nil}
    end
  end

  defp outcome(%{reason: :rate_limited} = failure, state) do
    seconds =
      case failure.retry_after_ms do
        ms when is_integer(ms) and ms > 0 -> max(1, div(ms + 999, 1000))
        _ -> state.config.rate_limit_snooze_seconds
      end

    {:snooze, seconds}
  end

  defp outcome(%{reason: reason}, _state) when reason in @terminal, do: {:cancel, reason}
  defp outcome(%{reason: reason}, _state), do: {:error, reason}

  defp land(record, state) do
    case Landing.land(record, scope: state.scope) do
      {:ok, _} -> :ok
      {:error, :scoped_landing_not_wired} -> {:stop, {:cancel, :scoped_landing_not_wired}, state}
      {:error, _details} -> {:stop, {:error, :landing_failed}, state}
    end
  end

  defp next_cursor(body) do
    case get_in(body, ["response_metadata", "next_cursor"]) do
      next when is_binary(next) and next != "" -> next
      _ -> nil
    end
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  # --- reporting: counts, ids and atoms only ----------------------------------------

  defp finish({:ok, state}, run_id), do: report({:ok, summary(state)}, state, run_id)
  defp finish({:stop, outcome, state}, run_id), do: report(outcome, state, run_id)

  defp summary(state), do: Map.put(state.counts, :more?, state.more?)

  defp report(outcome, state, run_id) do
    label = outcome_label(outcome)
    counts = state.counts

    :telemetry.execute(
      [:ash_enterprise, :integration, :slack, :sync_step],
      counts,
      %{linked_account_id: state.linked_account_id, outcome: label, more?: state.more?}
    )

    Logger.info(
      "slack sync step outcome=#{label} conversations=#{counts.conversations} " <>
        "messages=#{counts.messages} users=#{counts.users} resets=#{counts.resets} " <>
        "skipped=#{counts.skipped} more=#{state.more?}",
      linked_account_id: state.linked_account_id
    )

    case outcome do
      {:ok, _} -> lineage(:complete, run_id, [])
      {:snooze, _} -> lineage(:complete, run_id, [])
      {_, reason} -> lineage(:fail, run_id, reason: Atom.to_string(reason))
    end

    outcome
  end

  defp outcome_label({:ok, _}), do: :ok
  defp outcome_label({:snooze, _}), do: :rate_limited
  defp outcome_label({kind, reason}) when kind in [:cancel, :error], do: reason

  # Hole rule (ADR 0012): the sync is where data enters, so it emits its own
  # Job RunEvents. Structural names only — no account, actor or content.
  defp lineage(event, run_id, extra) do
    AshEnterprise.Lineage.ingestion_event(
      event,
      "ingestion",
      @lineage_job,
      [run_id: run_id, inputs: @lineage_inputs, outputs: @lineage_outputs] ++ extra
    )
  end
end
