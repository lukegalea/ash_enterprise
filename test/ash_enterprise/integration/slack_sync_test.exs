defmodule AshEnterprise.Integration.SlackSyncTest do
  @moduledoc """
  The Slack vertical (epic E4): the sync step, its worker and entry points,
  and the canonical projection.

  No network and no real data: every Slack response comes from an in-test fake
  workspace answered through the edge's `Req.Test` stub, and every payload is
  SYNTHETIC — shaped from Slack's public Web API reference
  (`conversations.list`, `conversations.history`, `users.info`), with
  `SYNTHETIC-` markers so the log test can prove none of it escapes.
  `NANGO_SECRET_KEY` is a fake value for the duration of each test.
  """

  # Application env, the OS environment and the Logger level are global.
  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import ExUnit.CaptureLog

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections.Slack, as: Projection
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Landing, LinkedAccount, Slack}
  alias AshEnterprise.Integration.Nango.Proxy

  alias AshEnterprise.Integration.Slack.{
    ConversationCursor,
    KnownMember,
    Records,
    Sync,
    Syncer,
    SyncWorker
  }

  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Security.ActorContext.Grant

  require Ash.Query

  @stub Proxy
  @fake_secret "nango-test-secret-not-a-real-key"
  @nango_env AshEnterprise.Integration.Nango
  @landing_env AshEnterprise.Integration.Landing
  @projection_env AshEnterprise.Canonical.Projections.Slack
  @worker_env AshEnterprise.Integration.Slack.SyncWorker
  @actors_env :slack_sync_test_actors

  @now ~U[2026-10-12 12:00:00.000000Z]

  # --- the synthetic workspace ------------------------------------------------------

  @general "C0SYNTH0GEN"
  @not_joined "C0SYNTH0OUT"
  @private "G0SYNTH0PRV"
  @dm "D0SYNTH0DM1"

  @alice_slack "U0SYNTHALI"
  @bob_slack "U0SYNTHBOB"
  @carol_slack "U0SYNTHCAR"

  defp channels do
    [
      %{
        "id" => @general,
        "name" => "synthetic-general",
        "is_channel" => true,
        "is_private" => false,
        "is_archived" => false,
        "is_member" => true,
        "created" => 1_700_000_000
      },
      %{
        "id" => @not_joined,
        "name" => "synthetic-not-joined",
        "is_channel" => true,
        "is_private" => false,
        "is_archived" => false,
        "is_member" => false,
        "created" => 1_700_000_000
      },
      %{
        "id" => @private,
        "name" => "synthetic-private",
        "is_channel" => false,
        "is_group" => true,
        "is_private" => true,
        "is_archived" => false,
        "is_member" => true,
        "created" => 1_700_000_000
      },
      %{
        "id" => @dm,
        "is_im" => true,
        "user" => @bob_slack,
        "is_user_deleted" => false,
        "created" => 1_700_000_000
      }
    ]
  end

  defp users do
    %{
      @alice_slack => member(@alice_slack, "Alice Synthetic", "alice.synthetic@example.test"),
      @bob_slack => member(@bob_slack, "Bob Synthetic", "bob.synthetic@example.test"),
      # users:read without users:read.email: no email in the profile.
      @carol_slack => member(@carol_slack, "Carol Synthetic", nil)
    }
  end

  defp member(id, real_name, email) do
    profile =
      %{"real_name" => real_name, "display_name" => String.downcase(real_name)}
      |> then(&if(email, do: Map.put(&1, "email", email), else: &1))

    %{
      "id" => id,
      "team_id" => "T0SYNTHTEAM",
      "name" => String.downcase(real_name),
      "real_name" => real_name,
      "deleted" => false,
      "is_bot" => false,
      "profile" => profile
    }
  end

  defp ts(hours_ago), do: Records.datetime_to_ts(DateTime.add(@now, -hours_ago * 3600, :second))

  defp msg(user, hours_ago, text, extra \\ %{}) do
    Map.merge(
      %{"type" => "message", "user" => user, "text" => text, "ts" => ts(hours_ago)},
      extra
    )
  end

  defp initial_messages do
    %{
      @general => [
        # Older than the 30-day backfill window: never requested.
        msg(@bob_slack, 24 * 40, "SYNTHETIC-TEXT-ANCIENT"),
        msg(@alice_slack, 10, "SYNTHETIC-TEXT-GEN-1"),
        msg(@bob_slack, 9, "SYNTHETIC-TEXT-GEN-2"),
        msg(@carol_slack, 8, "<@U0SYNTHCAR> has joined the channel", %{
          "subtype" => "channel_join"
        }),
        msg(@bob_slack, 7, "SYNTHETIC-TEXT-GEN-4")
      ],
      @private => [msg(@carol_slack, 6, "SYNTHETIC-TEXT-PRV-1")],
      @dm => [
        msg(@bob_slack, 5, "SYNTHETIC-TEXT-DM-1"),
        msg(@alice_slack, 4, "SYNTHETIC-TEXT-DM-2")
      ],
      @not_joined => [msg(@bob_slack, 3, "SYNTHETIC-TEXT-OUT-1")]
    }
  end

  # --- setup -----------------------------------------------------------------------

  setup do
    previous_secret = System.get_env("NANGO_SECRET_KEY")

    previous =
      for key <- [@nango_env, @landing_env, @projection_env, @worker_env, @actors_env, Syncer],
          into: %{},
          do: {key, Application.get_env(:ash_enterprise, key)}

    System.put_env("NANGO_SECRET_KEY", @fake_secret)

    Application.put_env(:ash_enterprise, @nango_env,
      base_url: "http://nango.test",
      req_options: [plug: {Req.Test, @stub}],
      sleep: fn _ms -> :ok end,
      base_backoff_ms: 1,
      max_attempts: 3,
      max_retry_delay_ms: 5_000
    )

    Application.put_env(:ash_enterprise, @landing_env, lander: __MODULE__.StoreLander)
    Application.put_env(:ash_enterprise, @worker_env, actor_loader: {__MODULE__.Actors, :load})
    Application.delete_env(:ash_enterprise, @projection_env)
    Process.put(:landed_to, self())

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("NANGO_SECRET_KEY", previous_secret),
        else: System.delete_env("NANGO_SECRET_KEY")

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:ash_enterprise, key, value),
          else: Application.delete_env(:ash_enterprise, key)
      end
    end)

    world = start_supervised!({Agent, fn -> new_world() end})
    fake_slack(world)

    org = organization("slack-sync")
    alice = user(org, "alice")
    bob = user(org, "bob")
    alice_slack = link!(alice, "slack", "conn-slack-alice-synthetic")

    Application.put_env(:ash_enterprise, @actors_env, %{alice.id => alice, bob.id => bob})

    %{world: world, org: org, alice: alice, bob: bob, alice_slack: alice_slack}
  end

  # --- first and incremental sync --------------------------------------------------------

  describe "first sync" do
    test "lands member conversations, their messages in the backfill window, and their authors",
         ctx do
      assert {:ok, summary} = step(ctx)

      assert summary == %{
               conversations: 3,
               messages: 7,
               users: 3,
               resets: 0,
               skipped: 0,
               more?: false
             }

      landed = drain_landed()
      scope = Landing.scope(ctx.alice_slack)
      assert Enum.all?(landed, &(&1.scope == scope))
      assert scope == ctx.alice_slack.id

      by_stream = Enum.group_by(landed, & &1.stream, & &1.external_id)
      la = ctx.alice_slack.id

      assert Enum.sort(by_stream["slack.conversations"]) ==
               Enum.sort(for c <- [@general, @private, @dm], do: "#{la}/conversation/#{c}")

      assert length(by_stream["slack.messages"]) == 7
      assert Enum.all?(by_stream["slack.messages"], &String.starts_with?(&1, "#{la}/message/"))
      refute Enum.any?(by_stream["slack.messages"], &String.contains?(&1, @not_joined))

      assert Enum.sort(by_stream["slack.users"]) ==
               Enum.sort(for u <- [@alice_slack, @bob_slack, @carol_slack], do: "#{la}/user/#{u}")

      # The non-member channel is listed by Slack but never read.
      refute Enum.any?(requests(ctx.world), &(&1.query["channel"] == @not_joined))

      # The first pass reached back exactly 30 days.
      floor = Records.datetime_to_ts(DateTime.add(@now, -30 * 24 * 3600, :second))
      history = history_requests(ctx.world, @general)
      assert [%{"oldest" => ^floor}] = history

      # Every conversation's high-water mark is its newest message.
      cursors = cursors(ctx.alice_slack)
      assert cursors[@general].latest_ts == ts(7)
      assert cursors[@private].latest_ts == ts(6)
      assert cursors[@dm].latest_ts == ts(4)
      assert Enum.all?(Map.values(cursors), &is_nil(&1.page_cursor))
      assert Enum.all?(Map.values(cursors), &(&1.synced_at == @now))
    end

    test "conversations.list is followed across pages", ctx do
      assert {:ok, %{conversations: 3}} = step(ctx, list_limit: 1)

      assert length(Enum.filter(requests(ctx.world), &(&1.path == "/proxy/conversations.list"))) ==
               4
    end
  end

  describe "incremental sync" do
    test "a second step asks only for what is newer than each conversation's cursor", ctx do
      assert {:ok, _} = step(ctx)
      drain_landed()
      reset_requests(ctx.world)

      add_messages(ctx.world, @general, [msg(@alice_slack, 2, "SYNTHETIC-TEXT-GEN-5")])
      add_messages(ctx.world, @dm, [msg(@bob_slack, 1, "SYNTHETIC-TEXT-DM-3")])

      assert {:ok, %{messages: 2, users: 0, more?: false}} = step(ctx)

      messages = drain_landed() |> Enum.filter(&(&1.stream == "slack.messages"))
      la = ctx.alice_slack.id

      assert Enum.sort(Enum.map(messages, & &1.external_id)) ==
               Enum.sort([
                 "#{la}/message/#{@general}/#{ts(2)}",
                 "#{la}/message/#{@dm}/#{ts(1)}"
               ])

      general_oldest = ts(7)
      assert [%{"oldest" => ^general_oldest}] = history_requests(ctx.world, @general)

      cursors = cursors(ctx.alice_slack)
      assert cursors[@general].latest_ts == ts(2)
      assert cursors[@dm].latest_ts == ts(1)
      assert cursors[@private].latest_ts == ts(6)
    end

    test "a step that runs out of budget resumes the same pass from the saved page cursor", ctx do
      assert {:ok, %{more?: true, messages: 5}} =
               step(ctx, history_limit: 2, max_pages_per_conversation: 1)

      general = cursors(ctx.alice_slack)[@general]
      assert general.page_cursor == "page:2"
      assert general.pass_latest_ts == ts(7)
      assert is_nil(general.latest_ts)

      reset_requests(ctx.world)

      assert {:ok, %{more?: false, messages: 2}} =
               step(ctx, history_limit: 2, max_pages_per_conversation: 1)

      floor = Records.datetime_to_ts(DateTime.add(@now, -30 * 24 * 3600, :second))
      assert [%{"cursor" => "page:2", "oldest" => ^floor}] = history_requests(ctx.world, @general)

      general = cursors(ctx.alice_slack)[@general]
      assert general.latest_ts == ts(7)
      assert is_nil(general.page_cursor)
      assert is_nil(general.pass_latest_ts)
    end

    test "the global page budget stops the step and says there is more", ctx do
      assert {:ok, %{more?: true}} = step(ctx, max_pages_per_step: 1)

      assert length(
               Enum.filter(requests(ctx.world), &(&1.path == "/proxy/conversations.history"))
             ) == 1
    end

    test "more conversations than the page budget: every one is reached and the job finishes",
         ctx do
      # 3 base member conversations + 6 more, against a budget of 3 pages a step.
      extra = extra_channels(ctx.world, 6)
      members = Enum.sort([@general, @private, @dm | extra])
      Application.put_env(:ash_enterprise, Syncer, max_pages_per_step: 3)
      args = %{"user_id" => ctx.alice.id, "linked_account_id" => ctx.alice_slack.id}

      outcomes =
        Enum.reduce_while(1..10, [], fn _, acc ->
          case perform_job(SyncWorker, args) do
            :ok -> {:halt, [:ok | acc]}
            other -> {:cont, [other | acc]}
          end
        end)

      # 9 never-visited conversations at 3 a step: snooze, snooze, then done.
      assert Enum.reverse(outcomes) == [{:snooze, 5}, {:snooze, 5}, :ok]
      assert history_channels(ctx.world) |> Enum.uniq() |> Enum.sort() == members
      assert ctx.alice_slack |> cursors() |> Map.keys() |> Enum.sort() == members

      # Everything is up to date now: a step that cannot reach every
      # conversation is not "more work", and the next step takes the ones it
      # did not reach — least recently visited first.
      reset_requests(ctx.world)
      assert {:ok, %{more?: false}} = Syncer.step(ctx.alice, nil, now: @now)
      first = history_channels(ctx.world)
      assert length(first) == 3

      reset_requests(ctx.world)
      assert :ok = perform_job(SyncWorker, args)
      second = history_channels(ctx.world)
      assert length(second) == 3
      assert MapSet.disjoint?(MapSet.new(first), MapSet.new(second))

      reset_requests(ctx.world)
      assert :ok = perform_job(SyncWorker, args)
      third = history_channels(ctx.world)
      assert Enum.sort(first ++ second ++ third) == members
    end

    test "a pass left part-way by the budget is still more work", ctx do
      assert {:ok, %{more?: true}} =
               step(ctx, history_limit: 1, max_pages_per_step: 1, max_pages_per_conversation: 5)

      assert cursors(ctx.alice_slack)[@general].page_cursor == "page:1"
    end

    test "members seen in a step without lookup budget are still fetched later", ctx do
      assert {:ok, %{users: 1, more?: true}} = step(ctx, max_user_lookups_per_step: 1)
      # No new messages: the remaining members come from the noted backlog.
      assert {:ok, %{messages: 0, users: 1, more?: true}} =
               step(ctx, max_user_lookups_per_step: 1)

      assert {:ok, %{users: 1, more?: false}} = step(ctx, max_user_lookups_per_step: 1)
      assert {:ok, %{users: 0, more?: false}} = step(ctx, max_user_lookups_per_step: 1)

      user_lookups =
        ctx.world |> requests() |> Enum.filter(&(&1.path == "/proxy/users.info"))

      assert user_lookups |> Enum.map(& &1.query["user"]) |> Enum.sort() ==
               Enum.sort([@alice_slack, @bob_slack, @carol_slack])
    end

    test "members are re-fetched once their profile is older than the refresh interval", ctx do
      assert {:ok, %{users: 3}} = step(ctx)
      later = DateTime.add(@now, 8 * 24 * 3600, :second)

      assert {:ok, %{users: 3}} = Syncer.step(ctx.alice, nil, now: later)
      assert {:ok, %{users: 0}} = Syncer.step(ctx.alice, nil, now: later)
    end
  end

  describe "Records" do
    test "membership: joined channels, IMs and MPIMs; not merely visible public channels" do
      assert Records.member?(%{"is_member" => true, "is_channel" => true})
      assert Records.member?(%{"is_im" => true})
      assert Records.member?(%{"is_mpim" => true})
      refute Records.member?(%{"is_member" => false, "is_channel" => true})
    end

    test "ts round-trips through DateTime at microsecond precision" do
      assert Records.datetime_to_ts(~U[2026-10-12 12:00:00.000100Z]) == "1791806400.000100"
      assert Records.ts_to_datetime("1791806400.000100") == ~U[2026-10-12 12:00:00.000100Z]
      assert Records.max_ts("1791806400.000100", "1791806399.999999") == "1791806400.000100"
      assert Records.max_ts(nil, "1.000001") == "1.000001"
      refute Records.ts?("1791806400")
    end
  end

  # --- cursor reset ---------------------------------------------------------------------

  describe "cursor reset path" do
    test "invalid_cursor triggers the explicit reset_pass: pass dropped, high-water mark kept",
         ctx do
      assert {:ok, _} = step(ctx)

      add_messages(ctx.world, @general, [
        msg(@bob_slack, 3, "SYNTHETIC-TEXT-GEN-6"),
        msg(@bob_slack, 2, "SYNTHETIC-TEXT-GEN-7")
      ])

      assert {:ok, %{more?: true}} = step(ctx, history_limit: 1, max_pages_per_conversation: 1)
      general = cursors(ctx.alice_slack)[@general]
      assert general.page_cursor == "page:1"
      assert general.latest_ts == ts(7)

      invalidate_cursor(ctx.world, "page:1")
      reset_requests(ctx.world)

      assert {:ok, %{resets: 1}} = step(ctx, history_limit: 1, max_pages_per_conversation: 1)

      general = cursors(ctx.alice_slack)[@general]
      assert is_nil(general.page_cursor)
      assert is_nil(general.pass_oldest)
      assert is_nil(general.pass_latest_ts)
      assert general.latest_ts == ts(7)

      # The next pass starts fresh from the high-water mark, without a cursor.
      reset_requests(ctx.world)
      assert {:ok, %{resets: 0}} = step(ctx)
      high_water = ts(7)
      assert [request] = history_requests(ctx.world, @general)
      assert request["oldest"] == high_water
      refute Map.has_key?(request, "cursor")
      assert cursors(ctx.alice_slack)[@general].latest_ts == ts(2)
    end

    test "rewind forgets the high-water mark so the next pass re-backfills", ctx do
      assert {:ok, _} = step(ctx)
      ConversationCursor.rewind!(cursors(ctx.alice_slack)[@general], authorize?: false)
      reset_requests(ctx.world)

      assert {:ok, %{messages: 4}} = step(ctx)
      floor = Records.datetime_to_ts(DateTime.add(@now, -30 * 24 * 3600, :second))
      assert [%{"oldest" => ^floor}] = history_requests(ctx.world, @general)
    end
  end

  # --- idempotence ----------------------------------------------------------------------

  describe "idempotent re-run" do
    test "re-running a completed step lands no new message", ctx do
      assert {:ok, %{messages: 7}} = step(ctx)
      rows_before = slack_source_objects()
      drain_landed()

      assert {:ok, %{messages: 0, users: 0}} = step(ctx)
      landed = drain_landed()
      refute Enum.any?(landed, &(&1.stream == "slack.messages"))

      assert slack_source_objects() == rows_before
    end

    test "re-fetching already-landed pages (after a rewind) duplicates nothing", ctx do
      assert {:ok, _} = step(ctx)
      rows_before = slack_source_objects()
      assert length(rows_before) == 13

      for cursor <- Map.values(cursors(ctx.alice_slack)) do
        ConversationCursor.rewind!(cursor, authorize?: false)
      end

      assert {:ok, %{messages: 7}} = step(ctx)
      assert slack_source_objects() == rows_before
    end
  end

  # --- refusals and failures ----------------------------------------------------------------

  describe "refusals" do
    test "with landing not wired, the step refuses before any request", ctx do
      Application.delete_env(:ash_enterprise, @landing_env)

      assert {:cancel, :scoped_landing_not_wired} = step(ctx)
      assert requests(ctx.world) == []
      assert cursors(ctx.alice_slack) == %{}
    end

    test "Slack rate limiting past the edge's retries snoozes for Retry-After", ctx do
      rate_limit_history(ctx.world, "30")

      assert {:snooze, 30} = step(ctx)
      assert cursors(ctx.alice_slack) == %{}

      # Members already seen (the DM counterpart) stay due for the next step.
      noted = KnownMember.for_account!(ctx.alice_slack.id, authorize?: false)
      assert [%{slack_user_id: @bob_slack, fetched_at: nil}] = noted

      # Once Slack lets us back in, the step picks up where it stopped.
      rate_limit_history(ctx.world, nil)
      assert {:ok, %{messages: 7, users: 3}} = step(ctx)
    end

    @tag :capture_log
    test "a conversation that keeps failing is skipped and does not block the others", ctx do
      # Sorted first by id, and failing with codes that are about the channel.
      fail_history(ctx.world, @general, "ekm_access_denied")
      fail_history(ctx.world, @private, "synthetic_unmapped_code")

      assert {:ok, %{skipped: 2, messages: 2, users: 2, more?: false}} = step(ctx)

      cursors = cursors(ctx.alice_slack)
      assert cursors[@dm].latest_ts == ts(4)
      # Skipped conversations are visited (so they rotate to the back) but not synced.
      assert is_nil(cursors[@general].latest_ts) and is_nil(cursors[@general].synced_at)
      assert is_nil(cursors[@private].latest_ts)

      # The worker finishes rather than retrying or cancelling the account.
      args = %{"user_id" => ctx.alice.id, "linked_account_id" => ctx.alice_slack.id}
      assert :ok = perform_job(SyncWorker, args)

      # Once the channel recovers it backfills from the window as normal.
      fail_history(ctx.world, @general, nil)
      fail_history(ctx.world, @private, nil)
      assert {:ok, %{skipped: 0, messages: 5}} = step(ctx)
      assert cursors(ctx.alice_slack)[@general].latest_ts == ts(7)
    end

    @tag :capture_log
    test "a skipped conversation drops its part-way pass but keeps its high-water mark", ctx do
      assert {:ok, _} = step(ctx)

      add_messages(ctx.world, @general, [
        msg(@bob_slack, 3, "SYNTHETIC-TEXT-GEN-6"),
        msg(@bob_slack, 2, "SYNTHETIC-TEXT-GEN-7")
      ])

      assert {:ok, %{more?: true}} = step(ctx, history_limit: 1, max_pages_per_conversation: 1)
      assert cursors(ctx.alice_slack)[@general].page_cursor == "page:1"

      fail_history(ctx.world, @general, "access_denied")
      assert {:ok, %{skipped: 1, more?: false}} = step(ctx)

      general = cursors(ctx.alice_slack)[@general]
      assert is_nil(general.page_cursor)
      assert general.latest_ts == ts(7)
    end

    test "account-level history failures still stop the step", ctx do
      fail_history(ctx.world, @dm, "missing_scope")
      assert {:cancel, :forbidden} = step(ctx)
    end

    test "a truncated conversations.list is reported, not silently dropped", ctx do
      test_pid = self()
      handler = "slack-sync-truncation-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ash_enterprise, :integration, :slack, :sync_step],
        fn _event, _measurements, metadata, _ -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      try do
        assert {:ok, _} = step(ctx, list_limit: 1, max_list_pages: 2)
        assert_received {:telemetry, %{list_truncated?: true}}

        assert {:ok, _} = step(ctx)
        assert_received {:telemetry, %{list_truncated?: false}}
      after
        :telemetry.detach(handler)
      end
    end

    test "a revoked token cancels: retrying cannot help", ctx do
      revoke_token(ctx.world)
      assert {:cancel, :unauthorized} = step(ctx)
    end

    test "another user's linked account resolves nothing and sends nothing", ctx do
      assert {:cancel, :no_linked_account} =
               Syncer.step(ctx.bob, ctx.alice_slack.id, now: @now)

      assert requests(ctx.world) == []
    end

    test "without the grant to call Slack, the step is refused and nothing is sent", ctx do
      no_slack =
        reattach(ctx.alice, ctx.org, Map.delete(grants(), {inspect(Slack), :read}))

      assert {:cancel, :policy_forbidden} = Syncer.step(no_slack, nil, now: @now)
      assert requests(ctx.world) == []
    end

    test "each linked account lands under its own scope and ids", ctx do
      second = link!(ctx.alice, "slack", "conn-slack-alice-second-synthetic")

      assert {:ok, _} = Syncer.step(ctx.alice, ctx.alice_slack.id, now: @now)
      first_landed = drain_landed()
      assert {:ok, _} = Syncer.step(ctx.alice, second.id, now: @now)
      second_landed = drain_landed()

      assert Enum.uniq(Enum.map(first_landed, & &1.scope)) == [Landing.scope(ctx.alice_slack)]
      assert Enum.uniq(Enum.map(second_landed, & &1.scope)) == [Landing.scope(second)]

      first_ids = MapSet.new(first_landed, & &1.external_id)
      second_ids = MapSet.new(second_landed, & &1.external_id)
      assert MapSet.disjoint?(first_ids, second_ids)

      # Two accounts for one integration: naming none is ambiguous.
      assert {:cancel, :ambiguous_linked_account} = Syncer.step(ctx.alice, nil, now: @now)
    end
  end

  # --- no content outside the lander ---------------------------------------------------------

  describe "no content leaves the step" do
    test "logs, telemetry, results and cursor rows carry no message text, names or emails", ctx do
      Application.put_env(:ash_enterprise, @landing_env, lander: __MODULE__.CapturingLander)

      test_pid = self()
      handler = "slack-sync-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ash_enterprise, :integration, :slack, :sync_step],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      previous_level = Logger.level()
      Logger.configure(level: :debug)

      log =
        try do
          capture_log([level: :debug], fn ->
            assert {:ok, result} = Sync.sync_step(%{}, actor: ctx.alice)
            send(test_pid, {:result, result})
          end)
        after
          Logger.configure(level: previous_level)
          :telemetry.detach(handler)
        end

      assert log =~ "slack sync step outcome=ok"

      assert_received {:result, result}
      assert_received {:telemetry, measurements, metadata}

      cursor_rows = ctx.alice_slack |> cursors() |> Map.values()

      leaks =
        for haystack <- [
              log,
              inspect(result),
              inspect({measurements, metadata}),
              inspect(cursor_rows)
            ],
            needle <- forbidden_strings(),
            String.contains?(haystack, needle),
            do: needle

      assert leaks == []
    end
  end

  # --- worker and entry points --------------------------------------------------------------

  describe "SyncWorker" do
    test "request_sync enqueues one job per account with string-keyed ids only", ctx do
      assert {:ok, %{conflict?: false, job_id: job_id, linked_account_id: la}} =
               Sync.request_sync(%{}, actor: ctx.alice)

      assert la == ctx.alice_slack.id

      assert [job] = all_enqueued(worker: SyncWorker)
      assert job.id == job_id
      assert job.queue == "ingestion"
      assert job.args == %{"user_id" => ctx.alice.id, "linked_account_id" => la}

      # Unique per linked account while queued.
      assert {:ok, %{conflict?: true, job_id: ^job_id}} =
               Sync.request_sync(%{linked_account_id: la}, actor: ctx.alice)

      assert [_] = all_enqueued(worker: SyncWorker)
    end

    test "request_sync cannot name another user's account", ctx do
      assert {:error, _} =
               Sync.request_sync(%{linked_account_id: ctx.alice_slack.id}, actor: ctx.bob)

      assert all_enqueued(worker: SyncWorker) == []
    end

    test "the entry points are policy-gated", ctx do
      no_sync = reattach(ctx.alice, ctx.org, Map.delete(grants(), {inspect(Sync), :read}))

      assert {:error, %Ash.Error.Forbidden{}} = Sync.sync_step(%{}, actor: no_sync)
      assert {:error, %Ash.Error.Forbidden{}} = Sync.request_sync(%{}, actor: no_sync)
      assert requests(ctx.world) == []
    end

    test "a finished step is :ok; a budget stop snoozes to continue; rate limits snooze", ctx do
      args = %{"user_id" => ctx.alice.id, "linked_account_id" => ctx.alice_slack.id}

      Application.put_env(:ash_enterprise, Syncer, max_pages_per_step: 1)
      assert {:snooze, 5} = perform_job(SyncWorker, args)

      Application.put_env(:ash_enterprise, Syncer, [])
      assert :ok = perform_job(SyncWorker, args)

      rate_limit_history(ctx.world, "30")
      add_messages(ctx.world, @general, [msg(@bob_slack, 1, "SYNTHETIC-TEXT-GEN-9")])
      assert {:snooze, 30} = perform_job(SyncWorker, args)
    end

    test "terminal outcomes cancel; malformed args cancel", ctx do
      Application.delete_env(:ash_enterprise, @landing_env)

      args = %{"user_id" => ctx.alice.id, "linked_account_id" => ctx.alice_slack.id}
      assert {:cancel, :scoped_landing_not_wired} = perform_job(SyncWorker, args)
      assert {:cancel, :invalid_args} = perform_job(SyncWorker, %{"linked_account_id" => "x"})

      assert {:cancel, :unknown_user} =
               perform_job(SyncWorker, %{
                 "user_id" => Ecto.UUID.generate(),
                 "linked_account_id" => ctx.alice_slack.id
               })
    end
  end

  # --- projection ----------------------------------------------------------------------------

  describe "canonical projection" do
    @describetag :tmp_dir

    test "is denied by default: no zone, nothing projected", ctx do
      assert {:ok, _} = step(ctx)

      assert {:error, {:not_admitted, :undeclared_zone}} = Projection.replay(ctx.alice)
      assert Conversation.read!(tenant: ctx.org.id, authorize?: false) == []
      assert Message.read!(tenant: ctx.org.id, authorize?: false) == []
    end

    test "is denied when the zone cannot hold Slack's tags", ctx do
      declare_zone(ctx.tmp_dir, data_class: :customer_confidential, residency: "US")
      assert {:ok, _} = step(ctx)

      assert {:error, {:not_admitted, :inadmissible_restriction}} = Projection.replay(ctx.alice)
      assert Message.read!(tenant: ctx.org.id, authorize?: false) == []
    end

    test "once admitted, projects public channels, their messages and emailed people deterministically",
         ctx do
      declare_zone(ctx.tmp_dir, data_class: :customer_confidential, residency: "CA")
      assert {:ok, _} = step(ctx)

      assert {:ok, %{conversations: 1, messages: 3, people: 2}} = Projection.replay(ctx.alice)

      assert [general] = Conversation.read!(tenant: ctx.org.id, authorize?: false)
      assert general.subject == "#synthetic-general"

      assert general.participants["slack_user_ids"] == [@alice_slack, @bob_slack, @carol_slack]

      assert general.participants["emails"] ==
               ["alice.synthetic@example.test", "bob.synthetic@example.test"]

      people = Person.read!(tenant: ctx.org.id, authorize?: false)

      assert people |> Enum.map(&to_string(&1.email)) |> Enum.sort() ==
               ["alice.synthetic@example.test", "bob.synthetic@example.test"]

      messages = Message.read!(tenant: ctx.org.id, authorize?: false)

      assert messages |> Enum.map(& &1.body) |> Enum.sort() ==
               ["SYNTHETIC-TEXT-GEN-1", "SYNTHETIC-TEXT-GEN-2", "SYNTHETIC-TEXT-GEN-4"]

      assert Enum.all?(messages, &(&1.owner_id == ctx.alice.id))
      assert Enum.all?(messages, &(&1.conversation_id == general.id))

      # Alice is the account holder (inferred from the DM, which is read for
      # that but not projected): her messages are outbound.
      outbound = messages |> Enum.filter(&(&1.direction == :outbound)) |> Enum.map(& &1.body)
      assert outbound == ["SYNTHETIC-TEXT-GEN-1"]

      bob_message = Enum.find(messages, &(&1.body == "SYNTHETIC-TEXT-GEN-2"))
      assert bob_message.sent_at == Records.ts_to_datetime(ts(9))
      bob = Enum.find(people, &(to_string(&1.email) == "bob.synthetic@example.test"))
      assert bob_message.sender_id == bob.id

      # Replay converges: same rows, same values.
      snapshot = canonical_snapshot(ctx.org)
      assert {:ok, %{conversations: 1, messages: 3, people: 2}} = Projection.replay(ctx.alice)
      assert canonical_snapshot(ctx.org) == snapshot
    end

    test "never writes a DM, group DM or private channel into the organization-owned table",
         ctx do
      declare_zone(ctx.tmp_dir, data_class: :customer_confidential, residency: "CA")

      add_channels(ctx.world, [
        %{
          "id" => "G0SYNTH0MPM",
          "name" => "mpdm-synthetic-group",
          "is_mpim" => true,
          "is_private" => true,
          "is_member" => true,
          "created" => 1_700_000_000
        },
        # A modern private channel: is_channel true, but private.
        %{
          "id" => "C0SYNTH0PRV",
          "name" => "synthetic-private-modern",
          "is_channel" => true,
          "is_private" => true,
          "is_member" => true,
          "created" => 1_700_000_000
        }
      ])

      add_messages(ctx.world, "G0SYNTH0MPM", [msg(@bob_slack, 2, "SYNTHETIC-TEXT-MPIM-1")])
      add_messages(ctx.world, "C0SYNTH0PRV", [msg(@bob_slack, 2, "SYNTHETIC-TEXT-PRV-2")])

      assert {:ok, %{conversations: 5}} = step(ctx)
      assert {:ok, %{conversations: 1}} = Projection.replay(ctx.alice)

      private_ids = [@dm, @private, "G0SYNTH0MPM", "C0SYNTH0PRV"]

      conversations = Conversation.read!(tenant: ctx.org.id, authorize?: false)
      assert Enum.map(conversations, & &1.subject) == ["#synthetic-general"]

      refute Enum.any?(conversations, fn c ->
               Enum.any?(private_ids, &String.ends_with?(c.external_id, "/" <> &1))
             end)

      bodies = Message.read!(tenant: ctx.org.id, authorize?: false) |> Enum.map(& &1.body)

      for body <- [
            "SYNTHETIC-TEXT-DM-1",
            "SYNTHETIC-TEXT-DM-2",
            "SYNTHETIC-TEXT-PRV-1",
            "SYNTHETIC-TEXT-PRV-2",
            "SYNTHETIC-TEXT-MPIM-1"
          ],
          do: refute(body in bodies)

      # Unprojected is not unlanded: the raw records stay under the shred scope.
      assert Enum.any?(slack_source_objects(), fn {_, external_id, _} ->
               String.ends_with?(external_id, "/conversation/" <> @dm)
             end)
    end

    test "public_channel? reads only the conversation's own record" do
      assert Projection.public_channel?(%{"is_channel" => true, "is_private" => false})
      refute Projection.public_channel?(%{"is_channel" => true, "is_private" => true})
      refute Projection.public_channel?(%{"is_channel" => true})
      refute Projection.public_channel?(%{"is_im" => true})
      refute Projection.public_channel?(%{"is_mpim" => true, "is_private" => true})
      refute Projection.public_channel?(%{"is_group" => true, "is_private" => true})
    end
  end

  # --- fake Slack (through the edge's Req.Test stub) ---------------------------------------

  defp new_world do
    %{
      channels: channels(),
      users: users(),
      messages: initial_messages(),
      requests: [],
      invalid_cursors: MapSet.new(),
      history_errors: %{},
      rate_limit_history: nil,
      revoked?: false
    }
  end

  defp fake_slack(world) do
    Req.Test.stub(@stub, fn conn ->
      query = conn.query_string |> URI.decode_query()

      Agent.update(
        world,
        &%{&1 | requests: [%{path: conn.request_path, query: query} | &1.requests]}
      )

      state = Agent.get(world, & &1)

      case respond(state, conn.request_path, query) do
        {:status, status, headers, body} ->
          conn
          |> put_resp_headers(headers)
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(body)

        body ->
          Req.Test.json(conn, body)
      end
    end)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      Plug.Conn.put_resp_header(conn, key, value)
    end)
  end

  defp respond(%{revoked?: true}, _path, _query), do: %{"ok" => false, "error" => "token_revoked"}

  defp respond(state, "/proxy/conversations.list", query) do
    page(state.channels, query, "channels")
  end

  defp respond(state, "/proxy/conversations.history", query) do
    cond do
      state.rate_limit_history ->
        {:status, 429, [{"retry-after", state.rate_limit_history}],
         %{"ok" => false, "error" => "ratelimited"}}

      MapSet.member?(state.invalid_cursors, query["cursor"]) ->
        %{"ok" => false, "error" => "invalid_cursor"}

      code = Map.get(state.history_errors, query["channel"]) ->
        %{"ok" => false, "error" => code}

      true ->
        oldest = query["oldest"]

        state.messages
        |> Map.get(query["channel"], [])
        |> Enum.filter(
          &(is_nil(oldest) or Records.ts_to_micro(&1["ts"]) > Records.ts_to_micro(oldest))
        )
        |> Enum.sort_by(&Records.ts_to_micro(&1["ts"]), :desc)
        |> page(query, "messages")
    end
  end

  defp respond(state, "/proxy/users.info", %{"user" => user_id}) do
    case Map.fetch(state.users, user_id) do
      {:ok, user} -> %{"ok" => true, "user" => user}
      :error -> %{"ok" => false, "error" => "user_not_found"}
    end
  end

  # Slack-shaped cursor pagination: an opaque next_cursor ("" on the last page).
  defp page(items, query, key) do
    offset =
      case query["cursor"] do
        "page:" <> n -> String.to_integer(n)
        _ -> 0
      end

    limit = String.to_integer(query["limit"] || "100")
    slice = Enum.slice(items, offset, limit)
    more? = offset + limit < length(items)

    %{
      "ok" => true,
      key => slice,
      "has_more" => more?,
      "response_metadata" => %{"next_cursor" => if(more?, do: "page:#{offset + limit}", else: "")}
    }
  end

  defp add_messages(world, channel, messages) do
    Agent.update(world, fn state ->
      update_in(state, [:messages, channel], &((&1 || []) ++ messages))
    end)
  end

  defp add_channels(world, channels),
    do: Agent.update(world, &%{&1 | channels: &1.channels ++ channels})

  defp fail_history(world, channel, nil),
    do: Agent.update(world, &%{&1 | history_errors: Map.delete(&1.history_errors, channel)})

  defp fail_history(world, channel, code),
    do: Agent.update(world, &%{&1 | history_errors: Map.put(&1.history_errors, channel, code)})

  defp history_channels(world) do
    world
    |> requests()
    |> Enum.filter(&(&1.path == "/proxy/conversations.history"))
    |> Enum.map(& &1.query["channel"])
  end

  # Joined public channels beyond the base workspace, one message each.
  defp extra_channels(world, n) do
    ids = for i <- 1..n, do: "C1SYNTH0X" <> String.pad_leading(Integer.to_string(i), 2, "0")

    add_channels(
      world,
      for id <- ids do
        %{
          "id" => id,
          "name" => "synthetic-extra-#{String.downcase(id)}",
          "is_channel" => true,
          "is_private" => false,
          "is_archived" => false,
          "is_member" => true,
          "created" => 1_700_000_000
        }
      end
    )

    for id <- ids, do: add_messages(world, id, [msg(@bob_slack, 2, "SYNTHETIC-TEXT-EXTRA")])
    ids
  end

  defp invalidate_cursor(world, cursor),
    do: Agent.update(world, &%{&1 | invalid_cursors: MapSet.put(&1.invalid_cursors, cursor)})

  defp rate_limit_history(world, retry_after),
    do: Agent.update(world, &%{&1 | rate_limit_history: retry_after})

  defp revoke_token(world), do: Agent.update(world, &%{&1 | revoked?: true})

  defp requests(world), do: world |> Agent.get(& &1.requests) |> Enum.reverse()
  defp reset_requests(world), do: Agent.update(world, &%{&1 | requests: []})

  defp history_requests(world, channel) do
    world
    |> requests()
    |> Enum.filter(
      &(&1.path == "/proxy/conversations.history" and &1.query["channel"] == channel)
    )
    |> Enum.map(&Map.drop(&1.query, ["channel", "limit"]))
  end

  # --- landers ---------------------------------------------------------------------------------

  defmodule StoreLander do
    @moduledoc false
    # The real scoped lander (sealed into SourceObject; synthetic data only),
    # which also reports what it landed under which scope ref.
    @behaviour AshEnterprise.Integration.Landing

    alias AshEnterprise.Integration.Landing.Scoped

    @impl true
    defdelegate open_scope(ref, attrs), to: Scoped

    @impl true
    def land(record, scope) do
      with {:ok, landed} <- Scoped.land(record, scope) do
        send(Process.get(:landed_to), {:landed, record.stream, record.external_id, scope.ref})
        {:ok, landed}
      end
    end
  end

  defmodule CapturingLander do
    @moduledoc false
    @behaviour AshEnterprise.Integration.Landing

    @impl true
    def land(record, scope_ref) do
      send(Process.get(:landed_to), {:landed, record.stream, record.external_id, scope_ref})
      {:ok, :captured}
    end
  end

  defmodule Actors do
    @moduledoc false
    def load(user_id) do
      case Map.fetch(Application.get_env(:ash_enterprise, :slack_sync_test_actors, %{}), user_id) do
        {:ok, actor} -> {:ok, actor}
        :error -> :error
      end
    end
  end

  defp drain_landed(acc \\ []) do
    receive do
      {:landed, stream, external_id, scope} ->
        drain_landed([%{stream: stream, external_id: external_id, scope: scope} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp step(ctx, opts \\ []), do: Syncer.step(ctx.alice, nil, Keyword.put(opts, :now, @now))

  defp cursors(linked_account) do
    linked_account.id
    |> ConversationCursor.for_account!(authorize?: false)
    |> Map.new(&{&1.channel_id, &1})
  end

  defp slack_source_objects do
    SourceObject
    |> Ash.Query.filter(external_system == "slack")
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.id, &1.external_id, &1.raw_payload})
  end

  defp canonical_snapshot(org) do
    opts = [tenant: org.id, authorize?: false]

    %{
      conversations:
        Conversation.read!(opts)
        |> Enum.map(&Map.take(&1, [:id, :external_id, :subject, :participants]))
        |> Enum.sort_by(& &1.external_id),
      messages:
        Message.read!(opts)
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :external_id,
            :body,
            :sent_at,
            :direction,
            :conversation_id,
            :sender_id
          ])
        )
        |> Enum.sort_by(& &1.external_id),
      people:
        Person.read!(opts)
        |> Enum.map(&Map.take(&1, [:id, :email, :name]))
        |> Enum.sort_by(&to_string(&1.email))
    }
  end

  defp forbidden_strings do
    texts =
      initial_messages()
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1["text"])

    names = Enum.flat_map(Map.values(users()), &[&1["real_name"], &1["profile"]["email"]])
    channel_names = channels() |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)

    Enum.reject(texts ++ names ++ channel_names, &is_nil/1)
  end

  defp declare_zone(tmp_dir, tags) do
    today = Date.utc_today()

    declaration = %{
      "id" => "test-slack-zone",
      "jurisdiction" => "CA-ON",
      "classification_ceiling" => "customer_confidential",
      "inadmissible_restrictions" => ["US"],
      "declared_by" => "Test Operator",
      "declared_at" => Date.to_iso8601(Date.add(today, -1)),
      "review_by" => Date.to_iso8601(Date.add(today, 30))
    }

    path = Path.join(tmp_dir, "test-slack-zone.json")
    File.write!(path, Jason.encode!(declaration))

    previous_zones = Application.get_env(:ash_enterprise, AshEnterprise.Zones)
    Application.put_env(:ash_enterprise, AshEnterprise.Zones, declarations: [path])

    on_exit(fn ->
      if previous_zones,
        do: Application.put_env(:ash_enterprise, AshEnterprise.Zones, previous_zones),
        else: Application.delete_env(:ash_enterprise, AshEnterprise.Zones)
    end)

    Application.put_env(
      :ash_enterprise,
      @projection_env,
      Keyword.merge([zone: "test-slack-zone"], tags)
    )
  end

  # The grants a dogfood operator holds: Basic on their own linked accounts,
  # Global read (= may call) on the Slack operations and the sync entry points.
  # Built directly, the way `LoadActorContext` would precompute them.
  defp grants do
    %{
      {inspect(LinkedAccount), :read} => %Grant{basic?: true},
      {inspect(LinkedAccount), :create} => %Grant{basic?: true},
      {inspect(Slack), :read} => %Grant{global?: true},
      {inspect(Sync), :read} => %Grant{global?: true}
    }
  end

  defp reattach(user, org, grants) do
    ActorContext.attach(user, %ActorContext{
      user_id: user.id,
      organization_id: org.id,
      principal_ids: [user.id],
      grants: grants
    })
  end

  defp organization(name) do
    unique = "#{name}-#{System.unique_integer([:positive])}"

    AshEnterprise.Accounts.Organization
    |> Ash.Changeset.for_create(:create, %{name: unique, unique_name: unique}, authorize?: false)
    |> Ash.create!()
  end

  defp user(org, name) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{name}-#{System.unique_integer([:positive])}@slack-sync.test",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> reattach(org, grants())
  end

  defp link!(actor, provider_config_key, connection_id) do
    LinkedAccount.link!(
      %{provider_config_key: provider_config_key, connection_id: connection_id},
      actor: actor,
      tenant: ActorContext.tenant(actor)
    )
  end
end
