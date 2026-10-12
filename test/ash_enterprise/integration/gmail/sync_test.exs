defmodule AshEnterprise.Integration.Gmail.SyncTest do
  @moduledoc """
  The Gmail vertical's sync (epic E4): request → Oban step → edge actions →
  landing under the linked account's scope, with the cursor committed only
  after what it covers has landed.

  No network and no real mail: every request is answered by
  `AshEnterprise.Test.GmailSyntheticMailbox` through `Req.Test`, every payload
  is synthetic, and landings go to a recording lander that persists nothing.
  `NANGO_SECRET_KEY` is a fake value for the duration of each test.

  The actor is built the way the worker builds it in production — the user
  loaded from the database, `ActorContext.build/1` over real role rows — so
  the grants are seeded rows, not a hand-made context.
  """

  # Application env, the OS environment and the Logger level are global.
  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import ExUnit.CaptureLog

  alias AshEnterprise.Integration.{Gmail, LinkedAccount}
  alias AshEnterprise.Integration.Gmail.{MessageList, SyncState, SyncWorker}
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.{AccessRight, ActorContext, Privilege}
  alias AshEnterprise.Security.ActorContext.Grant
  alias AshEnterprise.Test.{GmailRecordingLander, GmailSyntheticMailbox}

  @fake_secret "nango-test-secret-not-a-real-key"
  @nango_env AshEnterprise.Integration.Nango
  @landing_env AshEnterprise.Integration.Landing
  @sync_env AshEnterprise.Integration.Gmail.Sync

  setup do
    previous = %{
      secret: System.get_env("NANGO_SECRET_KEY"),
      nango: Application.get_env(:ash_enterprise, @nango_env),
      landing: Application.get_env(:ash_enterprise, @landing_env),
      sync: Application.get_env(:ash_enterprise, @sync_env),
      log_level: Logger.level()
    }

    on_exit(fn ->
      restore_os_env("NANGO_SECRET_KEY", previous.secret)
      restore_app_env(@nango_env, previous.nango)
      restore_app_env(@landing_env, previous.landing)
      restore_app_env(@sync_env, previous.sync)
      Logger.configure(level: previous.log_level)
    end)

    System.put_env("NANGO_SECRET_KEY", @fake_secret)

    Application.put_env(:ash_enterprise, @nango_env,
      base_url: "http://nango.test",
      req_options: [plug: {Req.Test, Proxy}],
      sleep: fn _ms -> :ok end,
      base_backoff_ms: 1,
      max_attempts: 3,
      max_retry_delay_ms: 5_000
    )

    Application.put_env(:ash_enterprise, @landing_env, lander: GmailRecordingLander)

    # Small numbers so paging and the backfill cap are exercised.
    Application.put_env(:ash_enterprise, @sync_env,
      backfill_window_days: 7,
      backfill_max_messages: 3,
      page_size: 2,
      max_pages_per_step: 10
    )

    start_supervised!(GmailRecordingLander)
    box = start_supervised!(GmailSyntheticMailbox)
    Req.Test.stub(Proxy, GmailSyntheticMailbox.plug(box))

    unique = System.unique_integer([:positive])

    %{organization: org, user: user} =
      Seeder.seed_tenant(
        unique_name: "gmail-sync-#{unique}",
        email: "gmail-sync-#{unique}@example.test"
      )

    grant_vertical_privileges(org.id)
    actor = actor_for(user.id)

    linked =
      LinkedAccount.link!(
        %{provider_config_key: "google-mail", connection_id: "conn-mail-synthetic-#{unique}"},
        actor: actor,
        tenant: org.id
      )

    %{box: box, org: org, user: user, actor: actor, linked: linked}
  end

  describe "first sync" do
    test "bootstrap reads the profile historyId, a bounded backfill lands recent mail", ctx do
      m1 = GmailSyntheticMailbox.add_message(ctx.box)
      _draft = GmailSyntheticMailbox.add_message(ctx.box, labels: ["DRAFT"])
      m3 = GmailSyntheticMailbox.add_message(ctx.box)
      m4 = GmailSyntheticMailbox.add_message(ctx.box)
      profile_history_id = GmailSyntheticMailbox.history_id(ctx.box)

      request_sync!(ctx)
      assert_enqueued(worker: SyncWorker, args: job_args(ctx))
      assert :ok = run_step(ctx)

      # Newest first, capped at three ids; the draft consumes a slot and is
      # not landed; the oldest message is outside the cap.
      assert GmailRecordingLander.landed_ids() == [m4, m3]
      refute m1 in GmailRecordingLander.landed_ids()

      for {record, scope} <- GmailRecordingLander.landings() do
        assert scope == "integration.linked_account:" <> ctx.linked.id
        assert record.external_system == "gmail"
        assert record.stream == "gmail.messages"
        assert record.raw_payload["id"] == record.external_id
        assert record.source_metadata["stream"] == "gmail.messages"
        assert record.source_metadata["linked_account_id"] == ctx.linked.id
        assert record.source_metadata["thread_id"] == record.raw_payload["threadId"]
        assert record.cursor == %{"phase" => "backfill", "historyId" => profile_history_id}
      end

      state = sync_state!(ctx)
      assert state.phase == :incremental
      assert state.history_id == profile_history_id
      assert state.backfill_page_token == nil
      assert state.last_synced_at

      list_queries = queries(ctx.box, "/proxy/gmail/v1/users/me/messages")
      assert Enum.all?(list_queries, &({"q", "newer_than:7d"} in &1))

      assert Enum.map(list_queries, &List.keyfind(&1, "maxResults", 0)) == [
               {"maxResults", "2"},
               {"maxResults", "1"}
             ]

      # messages.get asks for the full message.
      assert ctx.box
             |> GmailSyntheticMailbox.requests()
             |> Enum.filter(fn {path, _} -> String.contains?(path, "/messages/") end)
             |> Enum.all?(fn {_path, query} -> {"format", "full"} in query end)
    end
  end

  describe "incremental sync" do
    test "lands only what history added after the cursor, committing per page", ctx do
      GmailSyntheticMailbox.add_message(ctx.box)
      first_cursor = GmailSyntheticMailbox.history_id(ctx.box)
      assert :ok = run_step(ctx)
      assert length(GmailRecordingLander.landed_ids()) == 1

      m2 = GmailSyntheticMailbox.add_message(ctx.box)
      m3 = GmailSyntheticMailbox.add_message(ctx.box)
      m4 = GmailSyntheticMailbox.add_message(ctx.box)

      assert :ok = run_step(ctx)

      assert Enum.drop(GmailRecordingLander.landed_ids(), 1) == [m2, m3, m4]
      assert sync_state!(ctx).history_id == GmailSyntheticMailbox.history_id(ctx.box)

      # Two pages of one request: the second keeps the request's
      # startHistoryId and carries the page token.
      history = queries(ctx.box, "/proxy/gmail/v1/users/me/history")
      assert Enum.all?(history, &({"startHistoryId", first_cursor} in &1))
      assert Enum.all?(history, &({"historyTypes", "messageAdded"} in &1))
      assert Enum.any?(history, &List.keymember?(&1, "pageToken", 0))

      for {record, _scope} <- Enum.drop(GmailRecordingLander.landings(), 1) do
        assert record.cursor == %{"phase" => "incremental", "startHistoryId" => first_cursor}
      end
    end

    test "a message deleted between history and fetch is skipped, not an error", ctx do
      assert :ok = run_step(ctx)
      gone = GmailSyntheticMailbox.add_message(ctx.box)
      kept = GmailSyntheticMailbox.add_message(ctx.box)
      GmailSyntheticMailbox.delete_message(ctx.box, gone)

      assert :ok = run_step(ctx)
      assert GmailRecordingLander.landed_ids() == [kept]
      assert sync_state!(ctx).history_id == GmailSyntheticMailbox.history_id(ctx.box)
    end
  end

  describe "cursor reset" do
    test "an expired historyId is an explicit reset and a bounded resync", ctx do
      GmailSyntheticMailbox.add_message(ctx.box)
      assert :ok = run_step(ctx)
      before = sync_state!(ctx)
      assert before.reset_count == 0

      m2 = GmailSyntheticMailbox.add_message(ctx.box)
      GmailSyntheticMailbox.expire_history(ctx.box)

      assert :ok = run_step(ctx)

      state = sync_state!(ctx)
      assert state.reset_count == 1
      assert state.last_reset_reason == :history_expired
      assert state.last_reset_at
      assert state.phase == :incremental
      assert state.history_id == GmailSyntheticMailbox.history_id(ctx.box)

      # The resync re-read the profile and re-ran the bounded backfill.
      assert length(queries(ctx.box, "/proxy/gmail/v1/users/me/profile")) == 2
      assert m2 in GmailRecordingLander.landed_ids()
    end

    test "an operator can reset the cursor explicitly", ctx do
      assert :ok = run_step(ctx)
      state = SyncState.reset_sync!(sync_state!(ctx), %{}, actor: ctx.actor, tenant: ctx.org.id)

      assert state.phase == :bootstrap
      assert state.history_id == nil
      assert state.last_reset_reason == :operator
      assert state.reset_count == 1
    end
  end

  describe "idempotency" do
    test "re-running a completed step lands nothing twice", ctx do
      for _ <- 1..2, do: GmailSyntheticMailbox.add_message(ctx.box)

      assert :ok = run_step(ctx)
      landed = GmailRecordingLander.landed_ids()
      assert length(landed) == 2
      cursor = sync_state!(ctx).history_id

      assert :ok = run_step(ctx)
      assert :ok = run_step(ctx)

      assert GmailRecordingLander.landed_ids() == landed
      assert sync_state!(ctx).history_id == cursor
    end

    test "requesting a sync twice enqueues one job per account", ctx do
      request_sync!(ctx)
      request_sync!(ctx)

      assert [_one] = all_enqueued(worker: SyncWorker)
      assert [%SyncState{}] = Ash.read!(SyncState, actor: ctx.actor, tenant: ctx.org.id)
    end

    test "job args are string-keyed ids only", ctx do
      request_sync!(ctx)
      assert [job] = all_enqueued(worker: SyncWorker)
      assert job.args == job_args(ctx)
    end
  end

  describe "outcomes" do
    test "rate limited: snooze for Retry-After, cursor untouched", ctx do
      assert :ok = run_step(ctx)
      cursor = sync_state!(ctx).history_id
      GmailSyntheticMailbox.add_message(ctx.box)
      GmailSyntheticMailbox.rate_limit_history(ctx.box, 30)

      assert {:snooze, 30} = run_step(ctx)
      assert sync_state!(ctx).history_id == cursor

      assert :ok = run_step(ctx)
      assert length(GmailRecordingLander.landed_ids()) == 1
    end

    test "until scoped landing is wired, nothing lands and the cursor does not move", ctx do
      Application.delete_env(:ash_enterprise, @landing_env)
      GmailSyntheticMailbox.add_message(ctx.box)

      assert {:cancel, :scoped_landing_not_wired} = run_step(ctx)
      assert GmailRecordingLander.landed_ids() == []

      state = sync_state!(ctx)
      assert state.phase == :backfill
      assert state.history_id == nil
      assert state.backfill_landed == 0
    end

    test "a deactivated linked account stops the sync without a request", ctx do
      ctx.linked
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: ctx.actor, tenant: ctx.org.id)
      |> Ash.update!()

      assert {:cancel, :no_linked_account} = run_step(ctx)
      assert GmailSyntheticMailbox.requests(ctx.box) == []
    end

    test "missing job args cancel rather than retry" do
      assert {:cancel, :invalid_args} = perform_job(SyncWorker, %{"linked_account_id" => nil})
    end
  end

  describe "request_sync" do
    test "refuses a linked account that is not one of the actor's own Gmail accounts", ctx do
      slack =
        LinkedAccount.link!(
          %{
            provider_config_key: "slack",
            connection_id: "conn-slack-synthetic-#{System.unique_integer([:positive])}"
          },
          actor: ctx.actor,
          tenant: ctx.org.id
        )

      assert {:error, %Ash.Error.Invalid{}} =
               SyncState.request_sync(%{linked_account_id: slack.id},
                 actor: ctx.actor,
                 tenant: ctx.org.id
               )

      assert {:error, %Ash.Error.Invalid{}} =
               SyncState.request_sync(%{linked_account_id: Ecto.UUID.generate()},
                 actor: ctx.actor,
                 tenant: ctx.org.id
               )

      assert all_enqueued(worker: SyncWorker) == []
    end

    test "has no connection or provider argument" do
      for action <- Ash.Resource.Info.actions(SyncState), argument <- action.arguments do
        refute argument.name in [:connection_id, :connection, :provider_config_key]
      end

      refute :connection_id in Ash.Resource.Info.action(SyncState, :request_sync).accept
    end

    test "at Basic depth an operator reaches only their own cursor", ctx do
      alice = basic_actor(ctx.user, ctx.org)

      bob =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "bob-#{System.unique_integer([:positive])}@example.test",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create!()
        |> basic_actor(ctx.org)

      state =
        SyncState.request_sync!(%{linked_account_id: ctx.linked.id},
          actor: alice,
          tenant: ctx.org.id
        )

      assert state.owner_id == ctx.user.id

      assert {:error, %Ash.Error.Invalid{}} =
               SyncState.request_sync(%{linked_account_id: ctx.linked.id},
                 actor: bob,
                 tenant: ctx.org.id
               )

      assert Ash.read!(SyncState, actor: bob, tenant: ctx.org.id) == []

      assert {:error, %Ash.Error.Forbidden{}} =
               SyncState.reset_sync(state, %{}, actor: bob, tenant: ctx.org.id)

      assert {:ok, _} = SyncState.reset_sync(state, %{}, actor: alice, tenant: ctx.org.id)
    end
  end

  describe "logs" do
    test "no message content, address, connection id or secret reaches the log", ctx do
      Logger.configure(level: :debug)

      GmailSyntheticMailbox.add_message(ctx.box,
        cc: "\"Synthetic Cc\" <cc@example.synthetic.test>"
      )

      log =
        capture_log([level: :debug], fn ->
          request_sync!(ctx)
          assert :ok = run_step(ctx)
          GmailSyntheticMailbox.add_message(ctx.box)
          assert :ok = run_step(ctx)
          GmailSyntheticMailbox.expire_history(ctx.box)
          GmailSyntheticMailbox.add_message(ctx.box)
          assert :ok = run_step(ctx)
          GmailSyntheticMailbox.rate_limit_history(ctx.box, 30)
          assert {:snooze, _} = run_step(ctx)
        end)

      assert length(GmailRecordingLander.landed_ids()) >= 3

      # The capture is not vacuous: debug SQL for the cursor writes is in it.
      assert log =~ "integration_gmail_sync_states"

      for forbidden <- [
            "SYNTHETIC-SUBJECT",
            "SYNTHETIC-BODY",
            "SYNTHETIC-SNIPPET",
            Base.url_encode64("SYNTHETIC-BODY", padding: false),
            "synthetic.test",
            "Synthetic Sender",
            ctx.linked.connection_id,
            @fake_secret
          ] do
        refute log =~ forbidden, "log contains #{inspect(forbidden)}"
      end
    end
  end

  test "the backfill operation is a generated edge action like the edge's own" do
    action = Ash.Resource.Info.action(MessageList, :list_messages)
    assert action.type == :action

    assert Enum.map(action.arguments, & &1.name) -- [:linked_account_id] ==
             [:q, :page_token, :max_results, :label_ids, :include_spam_trash]

    assert Ash.Resource.Info.action(Gmail, :get_message)
  end

  # --- helpers -----------------------------------------------------------------

  defp request_sync!(ctx) do
    SyncState.request_sync!(%{linked_account_id: ctx.linked.id},
      actor: ctx.actor,
      tenant: ctx.org.id
    )
  end

  defp run_step(ctx), do: perform_job(SyncWorker, job_args(ctx))

  defp job_args(ctx), do: %{"user_id" => ctx.user.id, "linked_account_id" => ctx.linked.id}

  defp sync_state!(ctx) do
    SyncState.for_linked_account!(ctx.linked.id, actor: ctx.actor, tenant: ctx.org.id)
  end

  defp queries(box, path) do
    box
    |> GmailSyntheticMailbox.requests()
    |> Enum.filter(fn {request_path, _} -> request_path == path end)
    |> Enum.map(fn {_path, query} -> query end)
  end

  # The privilege rows a role can grant on the vertical's resources. Not in
  # the catalogue yet because the integration domains are not in
  # `config :ash_enterprise, :ash_domains` (an integration step); once they
  # are, `Seeder.seed_privileges/0` writes exactly these.
  defp grant_vertical_privileges(tenant) do
    for {resource, ownership} <- [
          {LinkedAccount, :user_owned},
          {Gmail, :none},
          {MessageList, :none},
          {SyncState, :user_owned}
        ],
        verb <- AccessRight.verbs() do
      legal = Privilege.legal_depths(ownership)
      entity = resource |> Module.split() |> List.last()

      Privilege
      |> Ash.Changeset.for_create(
        :create,
        %{
          resource_name: inspect(resource),
          access_right: verb,
          name: "prv#{verb |> to_string() |> Macro.camelize()}#{entity}",
          can_be_basic: :basic in legal,
          can_be_local: :local in legal,
          can_be_deep: :deep in legal,
          can_be_global: :global in legal
        },
        actor: SystemActor.seed()
      )
      |> Ash.create!()
    end

    Seeder.regrant_administrator_privileges(tenant)
  end

  # The grants a dogfood operator holds, precomputed the way LoadActorContext
  # would: Basic on their own linked accounts and cursor, Global read (= may
  # call) on the operation resources.
  defp basic_actor(user, org) do
    basic = %Grant{basic?: true}
    global = %Grant{global?: true}

    ActorContext.attach(user, %ActorContext{
      user_id: user.id,
      organization_id: org.id,
      principal_ids: [user.id],
      grants: %{
        {inspect(LinkedAccount), :read} => basic,
        {inspect(SyncState), :read} => basic,
        {inspect(SyncState), :create} => basic,
        {inspect(SyncState), :write} => basic,
        {inspect(Gmail), :read} => global,
        {inspect(MessageList), :read} => global
      }
    })
  end

  defp actor_for(user_id) do
    user = Ash.get!(AshEnterprise.Accounts.User, user_id, authorize?: false)
    ActorContext.attach(user, ActorContext.build(user))
  end

  defp restore_os_env(name, nil), do: System.delete_env(name)
  defp restore_os_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:ash_enterprise, key)
  defp restore_app_env(key, value), do: Application.put_env(:ash_enterprise, key, value)
end
