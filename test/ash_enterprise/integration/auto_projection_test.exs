defmodule AshEnterprise.Integration.AutoProjectionTest do
  @moduledoc """
  Gmail and Slack sync steps project what they landed (`Projections.Pending`):
  incrementally, as the account's owner, through the zone gate, idempotently,
  never past a shred, and never past a failure. Plus the operator's catch-up
  task.

  No network: every provider response is a `Req.Test` stub with synthetic
  payloads, landed by the real scoped lander.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import ExUnit.CaptureLog

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections
  alias AshEnterprise.Canonical.Projections.Pending
  alias AshEnterprise.Erasure
  alias AshEnterprise.Integration.{Gmail, LinkedAccount, ProjectionCursor, Slack}
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.GmailSyntheticMailbox

  @moduletag :tmp_dir

  @fake_secret "nango-test-secret-not-a-real-key"
  @app_envs [
    AshEnterprise.Integration.Slack.SyncWorker,
    AshEnterprise.Integration.Slack.Syncer,
    AshEnterprise.Integration.Gmail.Sync,
    AshEnterprise.Canonical.Projections.Gmail,
    AshEnterprise.Canonical.Projections.Slack,
    AshEnterprise.Canonical.Projections.ZoneAdmission,
    AshEnterprise.Zones
  ]

  defmodule RaisingGate do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.ZoneGate

    @impl true
    def admit(_source, _context), do: raise("AUTOPROJ-SYNTHETIC gate failure")
  end

  setup ctx do
    previous_secret = System.get_env("NANGO_SECRET_KEY")
    previous = Map.new(@app_envs, &{&1, Application.get_env(:ash_enterprise, &1)})

    System.put_env("NANGO_SECRET_KEY", @fake_secret)
    Enum.each(@app_envs, &Application.delete_env(:ash_enterprise, &1))
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      if previous_secret,
        do: System.put_env("NANGO_SECRET_KEY", previous_secret),
        else: System.delete_env("NANGO_SECRET_KEY")

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:ash_enterprise, key, value),
          else: Application.delete_env(:ash_enterprise, key)
      end

      Mix.shell(Mix.Shell.IO)
    end)

    unique = System.unique_integer([:positive])
    email = "autoproj-#{unique}@autoproj.synthetic.test"
    seeded = Seeder.seed_tenant(name: "AP #{unique}", unique_name: "ap-#{unique}", email: email)
    Seeder.grant_platform_operator(seeded.user)

    actor =
      ActorContext.attach(
        seeded.user,
        ActorContext.build(seeded.user, tenant: seeded.organization.id)
      )

    declare_zone(ctx.tmp_dir)

    %{org: seeded.organization, user: seeded.user, actor: actor, email: email, unique: unique}
  end

  # --- Gmail -------------------------------------------------------------------------

  describe "Gmail" do
    setup ctx do
      box = start_supervised!(GmailSyntheticMailbox)
      Req.Test.stub(Proxy, GmailSyntheticMailbox.plug(box))
      Map.put(ctx, :box, box)
    end

    test "a step projects exactly what landed since the last one, whole threads included",
         ctx do
      account = link!(ctx, "google-mail") |> tag!(ctx)

      GmailSyntheticMailbox.add_message(ctx.box, thread_id: "thread-a", subject: "AP-SUBJECT-A")
      GmailSyntheticMailbox.add_message(ctx.box, thread_id: "thread-b", subject: "AP-SUBJECT-B")

      assert :ok = perform_job(Gmail.SyncWorker, job(ctx, account))
      assert_watermark(account)
      assert length(messages(ctx)) == 2
      assert Enum.all?(messages(ctx), &(&1.owner_id == ctx.user.id))

      # A reply in thread A: only it is new, and the thread's conversation is
      # rewritten from every message in it, exactly as a full replay would.
      GmailSyntheticMailbox.add_message(ctx.box,
        thread_id: "thread-a",
        subject: "Re: AP-SUBJECT-A",
        from: "\"AP Replier\" <replier@autoproj.synthetic.test>"
      )

      assert {:ok, summary} = Gmail.Sync.step(ctx.actor, account.id)
      assert %{landed: 1, projection: %{pending: 1, projected: 1, failed: 0}} = summary
      assert length(messages(ctx)) == 3

      thread_a = Enum.find(conversations(ctx), &(&1.subject == "AP-SUBJECT-A"))
      assert "replier@autoproj.synthetic.test" in thread_a.participants["emails"]

      incremental = snapshot(ctx)

      assert {:ok, %{messages: 3}} =
               Projections.Gmail.replay(owner: ctx.user, tenant: ctx.org)

      assert snapshot(ctx) == incremental
    end

    test "re-running a projection is idempotent; nothing new means nothing written", ctx do
      account = link!(ctx, "google-mail") |> tag!(ctx)
      GmailSyntheticMailbox.add_message(ctx.box)
      GmailSyntheticMailbox.add_message(ctx.box)

      assert {:ok, %{projection: %{projected: 2}}} = Gmail.Sync.step(ctx.actor, account.id)
      before = snapshot(ctx)
      watermark = Pending.watermark(account.id)
      assert watermark

      # Oban's at-least-once: the same step again lands and projects nothing.
      assert {:ok, %{landed: 0, projection: %{pending: 0, projected: 0}}} =
               Gmail.Sync.step(ctx.actor, account.id)

      # The catch-up over everything converges on the same rows.
      assert %{pending: 2, projected: 2, failed: 0} =
               Pending.project(account, owner: ctx.actor, all?: true)

      assert snapshot(ctx) == before
      assert Pending.watermark(account.id) == watermark
    end

    test "an untagged account's records are counted by reason, not projected", ctx do
      account = link!(ctx, "google-mail")
      GmailSyntheticMailbox.add_message(ctx.box)
      GmailSyntheticMailbox.add_message(ctx.box)

      capture_log(fn ->
        assert {:ok, %{projection: projection}} = Gmail.Sync.step(ctx.actor, account.id)

        assert %{pending: 2, projected: 0, denied: 2, denied_by: %{untagged_data_class: 2}} =
                 projection
      end)

      assert messages(ctx) == []
      assert conversations(ctx) == []

      # Refusals are not retried every step: the watermark moved past them.
      assert {:ok, %{projection: %{pending: 0}}} = Gmail.Sync.step(ctx.actor, account.id)

      # Once tagged, the operator's catch-up projects them.
      tag!(account, ctx)
      Mix.Tasks.AshEnterprise.Integration.Project.run(["--linked-account", account.id])
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "project google-mail status=complete"
      assert line =~ "projected=2"
      assert line =~ "denied_by=none"
      refute line =~ "@"
      assert length(messages(ctx)) == 2
    end

    test "a shred between landing and projection wins: nothing is projected", ctx do
      account = link!(ctx, "google-mail") |> tag!(ctx)
      GmailSyntheticMailbox.add_message(ctx.box, body: "AP-SYNTHETIC-BODY-SHRED")

      assert {:ok, summary} = Gmail.Sync.step(ctx.actor, account.id, project?: false)
      assert summary.landed == 1
      refute Map.has_key?(summary, :projection)

      shred!(ctx, account)

      assert %{pending: 1, projected: 0, shredded: 1, failed: 0} =
               Pending.project(account, owner: ctx.actor)

      assert messages(ctx) == []
      assert conversations(ctx) == []
      assert people(ctx) == []
    end

    test "a projection that fails keeps its records for the next step", ctx do
      account = link!(ctx, "google-mail") |> tag!(ctx)
      GmailSyntheticMailbox.add_message(ctx.box)

      Application.put_env(:ash_enterprise, Projections.Gmail, zone_gate: RaisingGate)

      log =
        capture_log(fn ->
          assert {:ok, %{landed: 1, projection: projection}} =
                   Gmail.Sync.step(ctx.actor, account.id)

          assert projection.projection_error == :projection_failed
        end)

      # Structural: the exception's module, never its message.
      assert log =~ "pending projection failed"
      refute log =~ "AUTOPROJ-SYNTHETIC"
      assert Pending.watermark(account.id) == nil
      assert messages(ctx) == []

      # Landed, not lost: the next step projects it without re-fetching it.
      Application.put_env(:ash_enterprise, Projections.Gmail,
        zone_gate: Projections.ZoneAdmission
      )

      assert {:ok, %{landed: 0, projection: %{pending: 1, projected: 1}}} =
               Gmail.Sync.step(ctx.actor, account.id)

      assert [_] = messages(ctx)
    end

    test "the sync task prints the projection counts, never content", ctx do
      account = link!(ctx, "google-mail") |> tag!(ctx)
      GmailSyntheticMailbox.add_message(ctx.box, subject: "AP-SYNTHETIC-SUBJECT-TASK")

      Mix.Tasks.AshEnterprise.Integration.Sync.run(["--linked-account", account.id])
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "google-mail status=complete"
      assert line =~ "landed=1"
      assert line =~ "pending=1"
      assert line =~ "projected=1"
      assert line =~ "denied_by=none"
      refute line =~ "AP-SYNTHETIC"
    end
  end

  # --- Slack -------------------------------------------------------------------------

  @channel "C0APSYNTH"
  @self_user "U0APSELF"
  @other_user "U0APOTHER"

  describe "Slack" do
    setup ctx do
      history = start_supervised!({Agent, fn -> [] end})
      stub_slack(history)
      Map.put(ctx, :history, history)
    end

    test "a step projects its new messages; participants and senders match a replay", ctx do
      account = link!(ctx, "slack") |> tag!(ctx)
      post(ctx.history, @other_user, "AP-SLACK-1", 3)
      post(ctx.history, @self_user, "AP-SLACK-2", 2)

      assert :ok = perform_job(Slack.SyncWorker, job(ctx, account))
      assert_watermark(account)
      assert [conversation] = conversations(ctx)
      assert conversation.subject == "#ap-synthetic-channel"
      assert length(messages(ctx)) == 2

      # One new message, from a member whose person already exists: only it is
      # written, its sender is linked, and the conversation keeps both authors.
      post(ctx.history, @other_user, "AP-SLACK-3", 1)

      assert {:ok, %{outcome: :ok, messages: 1, projection: projection}} =
               Slack.Sync.sync_step(%{linked_account_id: account.id}, actor: ctx.actor)

      assert %{projected: 1, people: 0, failed: 0} = projection

      new = Enum.find(messages(ctx), &(&1.body == "AP-SLACK-3"))
      other = Enum.find(people(ctx), &(to_string(&1.email) == "other@autoproj.synthetic.test"))
      assert new.sender_id == other.id
      assert new.direction == :inbound

      assert [conversation] = conversations(ctx)
      assert conversation.participants["slack_user_ids"] == Enum.sort([@other_user, @self_user])

      incremental = snapshot(ctx)

      assert {:ok, %{messages: 3}} = Projections.Slack.replay(ctx.actor, account.id)
      assert snapshot(ctx) == incremental

      # Nothing new: nothing projected, nothing rewritten.
      assert {:ok, %{projection: %{projected: 0, people: 0}}} =
               Slack.Sync.sync_step(%{linked_account_id: account.id}, actor: ctx.actor)

      assert snapshot(ctx) == incremental
    end

    test "an untagged account's records are counted by reason, not projected", ctx do
      account = link!(ctx, "slack")
      post(ctx.history, @other_user, "AP-SLACK-UNTAGGED", 1)

      capture_log(fn ->
        assert {:ok, %{projection: %{projected: 0, denied_by: denied_by}}} =
                 Slack.Sync.sync_step(%{linked_account_id: account.id}, actor: ctx.actor)

        # The conversation, the message and its author.
        assert denied_by == %{untagged_data_class: 3}
      end)

      assert messages(ctx) == []
      assert conversations(ctx) == []
    end

    test "a shred between landing and projection wins: nothing is projected", ctx do
      account = link!(ctx, "slack") |> tag!(ctx)
      post(ctx.history, @other_user, "AP-SLACK-SHRED", 1)

      assert {:ok, summary} = Slack.Syncer.step(ctx.actor, account.id, project?: false)
      refute Map.has_key?(summary, :projection)

      shred!(ctx, account)

      assert %{projected: 0, shredded: 3} = Pending.project(account, owner: ctx.actor)
      assert messages(ctx) == []
      assert conversations(ctx) == []
      assert people(ctx) == []
    end

    test "the catch-up task projects everything landed before projection ran", ctx do
      account = link!(ctx, "slack") |> tag!(ctx)
      post(ctx.history, @other_user, "AP-SLACK-CATCHUP-1", 2)
      post(ctx.history, @self_user, "AP-SLACK-CATCHUP-2", 1)

      assert {:ok, _} = Slack.Syncer.step(ctx.actor, account.id, project?: false)
      assert messages(ctx) == []

      Mix.Tasks.AshEnterprise.Integration.Project.run(["--linked-account", account.id])
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "project slack status=complete"
      assert line =~ "pending=5"
      assert line =~ "projected=2"
      refute line =~ "AP-SLACK"
      assert length(messages(ctx)) == 2

      # The catch-up moved the watermark: the next step has nothing pending
      # beyond the conversation records every step re-lands.
      assert {:ok, %{projection: %{projected: 0}}} =
               Slack.Sync.sync_step(%{linked_account_id: account.id}, actor: ctx.actor)

      assert_raise Mix.Error, ~r/no linked account/, fn ->
        Mix.Tasks.AshEnterprise.Integration.Project.run([
          "--linked-account",
          Ecto.UUID.generate()
        ])
      end
    end
  end

  # --- helpers ------------------------------------------------------------------------

  defp job(ctx, account), do: %{"user_id" => ctx.user.id, "linked_account_id" => account.id}

  defp link!(ctx, integration) do
    LinkedAccount.link!(
      %{provider_config_key: integration, connection_id: "conn-ap-#{integration}-#{ctx.unique}"},
      actor: ctx.actor,
      tenant: ctx.org.id
    )
  end

  defp tag!(account, ctx) do
    LinkedAccount.tag_for_zone!(account, %{data_class: :internal, residency: "CA"},
      tenant: ctx.org.id,
      authorize?: false
    )
  end

  # A worker's result is only the job's outcome: the projection it ran shows
  # in the watermark it moved and the canonical rows.
  defp assert_watermark(account) do
    assert %ProjectionCursor{projected_through: %DateTime{}} =
             ProjectionCursor.for_account!(account.id, authorize?: false)
  end

  defp shred!(ctx, account) do
    Mix.Tasks.AshEnterprise.Erasure.Shred.run([
      "connection:#{account.id}",
      "--as",
      ctx.email,
      "--reason",
      "auto-projection test",
      "--yes"
    ])

    assert %{status: :shredded} =
             Erasure.scope_by_ref!(:connection, account.id, authorize?: false)
  end

  defp messages(ctx), do: Message.read!(tenant: ctx.org.id, authorize?: false)
  defp conversations(ctx), do: Conversation.read!(tenant: ctx.org.id, authorize?: false)
  defp people(ctx), do: Person.read!(tenant: ctx.org.id, authorize?: false)

  defp snapshot(ctx) do
    %{
      conversations:
        ctx
        |> conversations()
        |> Enum.map(&Map.take(&1, [:id, :external_id, :subject, :participants]))
        |> Enum.sort_by(& &1.external_id),
      messages:
        ctx
        |> messages()
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
        ctx
        |> people()
        |> Enum.map(&Map.take(&1, [:id, :email, :name]))
        |> Enum.sort_by(&to_string(&1.email))
    }
  end

  defp declare_zone(tmp_dir) do
    today = Date.utc_today()
    path = Path.join(tmp_dir, "autoproj-zone.json")

    File.write!(
      path,
      Jason.encode!(%{
        "id" => "autoproj-zone",
        "jurisdiction" => "CA-ON",
        "classification_ceiling" => "customer_confidential",
        "inadmissible_restrictions" => ["US"],
        "declared_by" => "Test Operator",
        "declared_at" => Date.to_iso8601(Date.add(today, -1)),
        "review_by" => Date.to_iso8601(Date.add(today, 30))
      })
    )

    Application.put_env(:ash_enterprise, AshEnterprise.Zones, declarations: [path])
    Application.put_env(:ash_enterprise, Projections.ZoneAdmission, zone: "autoproj-zone")
    Application.put_env(:ash_enterprise, Projections.Gmail, zone_gate: Projections.ZoneAdmission)
    Application.put_env(:ash_enterprise, Projections.Slack, zone_gate: Projections.ZoneAdmission)
  end

  # --- the Slack stub --------------------------------------------------------------------

  defp post(history, user, text, hours_ago) do
    ts =
      DateTime.utc_now()
      |> DateTime.add(-hours_ago * 3600, :second)
      |> Records.datetime_to_ts()

    Agent.update(
      history,
      &[%{"type" => "message", "user" => user, "text" => text, "ts" => ts} | &1]
    )
  end

  defp stub_slack(history) do
    channel = %{
      "id" => @channel,
      "name" => "ap-synthetic-channel",
      "is_channel" => true,
      "is_private" => false,
      "is_archived" => false,
      "is_member" => true
    }

    users = %{
      @self_user => slack_user(@self_user, "AP Self", "self@autoproj.synthetic.test"),
      @other_user => slack_user(@other_user, "AP Other", "other@autoproj.synthetic.test")
    }

    Req.Test.stub(Proxy, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        case conn.request_path do
          "/proxy/conversations.list" ->
            %{
              "ok" => true,
              "channels" => [channel],
              "response_metadata" => %{"next_cursor" => ""}
            }

          "/proxy/conversations.history" ->
            %{
              "ok" => true,
              "messages" => newer_than(Agent.get(history, & &1), conn.query_params["oldest"]),
              "has_more" => false,
              "response_metadata" => %{"next_cursor" => ""}
            }

          "/proxy/users.info" ->
            %{"ok" => true, "user" => Map.fetch!(users, conn.query_params["user"])}
        end

      Req.Test.json(conn, body)
    end)
  end

  # `oldest` is exclusive, as Slack's.
  defp newer_than(messages, nil), do: messages

  defp newer_than(messages, oldest) do
    Enum.filter(messages, &(Records.ts_to_micro(&1["ts"]) > Records.ts_to_micro(oldest)))
  end

  defp slack_user(id, name, email) do
    %{
      "id" => id,
      "team_id" => "T0APSYNTH",
      "name" => String.downcase(name),
      "real_name" => name,
      "deleted" => false,
      "is_bot" => false,
      "profile" => %{"real_name" => name, "display_name" => name, "email" => email}
    }
  end
end
