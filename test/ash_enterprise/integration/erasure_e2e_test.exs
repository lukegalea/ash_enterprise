defmodule AshEnterprise.Integration.ErasureE2ETest do
  @moduledoc """
  Crypto-shredding wired through the provider edge, one vertical at a time
  (ADR 0024 + ADR 0011): link a Nango connection with the operator task, sync
  it through the stubbed Nango proxy, land, project, then shred the linked
  account's scope with the operator task — and prove that the raw landings,
  the canonical rows and the **entire** audit log hold none of the synthetic
  content, and that the next sync step is refused cleanly before it fetches
  anything.

  No network: every provider response is a `Req.Test` stub with synthetic,
  `E2E-SYNTHETIC` / fixture-marked payloads. The operator is a tenant
  Administrator provisioned *before* the Integration domain existed (its
  Integration and erasure grants are stripped) and brought up to date by
  `Seeder.seed_privileges/0` + `Seeder.regrant_administrator_privileges/1`,
  which is the documented upgrade path, then made the platform operator
  (`Seeder.grant_platform_operator/1`), the only holder of the shred grant.
  """

  use AshEnterprise.DataCase, async: false

  use Oban.Testing,
    repo: AshEnterprise.Repo,
    prefix: :ash_enterprise |> Application.get_env(Oban, []) |> Keyword.get(:prefix, "public")

  require Ash.Query

  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{Scope, Shredded}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.{Calendar, Gmail, LinkedAccount, Slack, SyncScheduler}
  alias AshEnterprise.Integration.Nango.Proxy
  alias AshEnterprise.Integration.Slack.Records
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.CalendarFixtures, as: F
  alias AshEnterprise.Test.GmailSyntheticMailbox

  @fake_secret "nango-test-secret-not-a-real-key"
  @app_envs [
    AshEnterprise.Integration.Calendar,
    AshEnterprise.Integration.Slack.SyncWorker,
    AshEnterprise.Integration.Slack.Syncer,
    AshEnterprise.Integration.Gmail.Sync,
    AshEnterprise.Canonical.Projections.Gmail,
    AshEnterprise.Canonical.Projections.Slack,
    AshEnterprise.Canonical.Projections.ZoneAdmission,
    AshEnterprise.Zones
  ]

  setup do
    previous_secret = System.get_env("NANGO_SECRET_KEY")
    previous = Map.new(@app_envs, &{&1, Application.get_env(:ash_enterprise, &1)})

    System.put_env("NANGO_SECRET_KEY", @fake_secret)
    # The real actor loaders, the real lander, deny-by-default zone gates.
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
    email = "operator-#{unique}@e2e.synthetic.test"

    seeded =
      Seeder.seed_tenant(name: "E2E #{unique}", unique_name: "e2e-#{unique}", email: email)

    org = seeded.organization

    # A tenant provisioned before this change: its Administrator holds nothing
    # on the Integration resources or on erasure scopes...
    Repo.query!(
      """
      DELETE FROM role_privileges
       WHERE organization_id = $1::uuid
         AND privilege_id IN (
           SELECT id FROM privileges
            WHERE resource_name LIKE 'AshEnterprise.Integration.%'
               OR resource_name = 'AshEnterprise.Erasure.Scope')
      """,
      [Ecto.UUID.dump!(org.id)]
    )

    # ...until the documented upgrade: `mix ash_enterprise.seed --privileges-only`
    # then the Administrator regrant.
    Seeder.seed_privileges()
    assert Seeder.regrant_administrator_privileges(org.id) > 0

    # The regrant never hands an Administrator the operator-only privileges
    # (raw landings, erasure scopes): shredding is the platform operator's.
    refute erasure_write?(seeded.user, org.id)
    assert %{granted: granted} = Seeder.grant_platform_operator(seeded.user)
    assert granted > 0
    assert erasure_write?(seeded.user, org.id)

    actor = ActorContext.attach(seeded.user, ActorContext.build(seeded.user, tenant: org.id))

    # Free text the operator types for an account: it must never reach the
    # audit log (LinkedAccount.label is sensitive), checked after every shred.
    label = "E2E-SYNTHETIC-LABEL-#{unique}"

    %{org: org, user: seeded.user, actor: actor, email: email, unique: unique, label: label}
  end

  defp erasure_write?(user, org_id) do
    context = ActorContext.build(user, tenant: org_id)
    ActorContext.grant(context, Scope, :write).global?
  end

  # --- Google Calendar -------------------------------------------------------------

  describe "Google Calendar" do
    test "sync, land, project, shred: nothing readable is left, and the next step is refused",
         ctx do
      account = link_via_task!(ctx, "google-calendar", "conn-cal-e2e-#{ctx.unique}")
      assert_accounts_task_lists(ctx, account, "active")

      stub_calendar()

      # The first step through the operator task: counts only, no content.
      Mix.Tasks.AshEnterprise.Integration.Sync.run(["--linked-account", account.id])
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "google-calendar status=complete"
      assert line =~ "landed=3"
      assert line =~ "projected=3"
      refute_spells(line, F.content_strings())

      scope = scope!(account)
      events = calendar_events(ctx)
      assert length(events) == 3
      assert Enum.all?(events, &(&1.erasure_scope_id == scope.id))
      assert Enum.any?(events, &(&1.title == "#{F.marker()} planning block"))
      assert Enum.all?(landed("google_calendar"), &(&1.erasure_scope_id == scope.id))

      # Sealed at rest from the start: no table holds the content in plaintext.
      # The one exception is the sync cursor's calendar id (a primary
      # calendar's id is the owner's address): bookkeeping, never audited, and
      # deleted with the linked account on unlink -- asserted at the end.
      assert_no_plaintext(F.content_strings(), calendar_ids())

      shred_via_task!(ctx, account)

      assert Enum.all?(landed("google_calendar"), &Shredded.shredded?(&1.raw_payload))
      assert Enum.all?(calendar_events(ctx), &Shredded.shredded?(&1.title))
      assert_no_plaintext(F.content_strings(), calendar_ids())
      assert_no_audit_event_spells(F.content_strings())
      assert_accounts_task_lists(ctx, account, "shredded")

      # A replay finds nothing left to project.
      assert {:ok, %{shredded: 3, projected: 0}} =
               Projections.Calendar.replay_landed(account.id, %{
                 owner_id: ctx.user.id,
                 tenant_id: ctx.org.id
               })

      # The next scheduled step is refused before it asks the provider anything.
      tripwire()

      assert {:cancel, "landing_refused: scope_shredded"} =
               perform_job(Calendar.SyncWorker, Calendar.SyncWorker.args(account))

      refute_received {:provider_request, _path}

      # ...and the account is blocked, so the scheduler stops enqueuing a
      # cancelled step for it every tick.
      assert blocked_reason(account) == "scope_shredded"
      assert %{accounts: 0} = SyncScheduler.enqueue("google-calendar")
      assert length(landed("google_calendar")) == 3
      assert_no_plaintext(F.content_strings(), calendar_ids())

      # Unlinking forgets the mapping and its cursors: no table is left
      # spelling anything the account brought in, bar canonical_people (below).
      LinkedAccount.unlink!(account, actor: ctx.actor, tenant: ctx.org.id)
      assert_no_plaintext(F.content_strings())
    end

    test "a correspondent's name and email outlive a shred in canonical_people (documented gap)",
         ctx do
      account = link_via_task!(ctx, "google-calendar", "conn-cal-people-#{ctx.unique}")
      stub_calendar()
      assert {:ok, _} = perform_job(Calendar.SyncWorker, Calendar.SyncWorker.args(account))
      shred_via_task!(ctx, account)

      # Not sealed (shared across sources, upserted on email); sensitive, so
      # the audit log never holds them, but the row does.
      assert Person
             |> Ash.read!(tenant: ctx.org.id, authorize?: false)
             |> Enum.any?(&(to_string(&1.email) == "ada@example.test"))

      assert_no_audit_event_spells(["ada@example.test", "Ada #{F.marker()}"])
    end
  end

  # --- Gmail ---------------------------------------------------------------------------

  describe "Gmail" do
    @tag :tmp_dir
    test "sync, land, admit on the account's tags, project, shred: nothing readable is left",
         ctx do
      account = link_via_task!(ctx, "google-mail", "conn-mail-e2e-#{ctx.unique}")

      box = start_supervised!(GmailSyntheticMailbox)
      Req.Test.stub(Proxy, GmailSyntheticMailbox.plug(box))

      for n <- 1..2 do
        GmailSyntheticMailbox.add_message(box,
          subject: "E2E-SYNTHETIC-SUBJECT-#{n}",
          body: "E2E-SYNTHETIC-BODY-#{n} the churn number",
          from: "\"E2E Synthetic Sender\" <e2e.sender#{n}@example.synthetic.test>"
        )
      end

      content = gmail_content()
      job = %{"user_id" => ctx.user.id, "linked_account_id" => account.id}

      assert :ok = perform_job(Gmail.SyncWorker, job)
      scope = scope!(account)
      assert [_, _] = landed("gmail")
      assert Enum.all?(landed("gmail"), &(&1.erasure_scope_id == scope.id))

      # Deny by default: nothing is projected until a zone gate admits it.
      assert {:ok, %{admitted: 0, messages: 0}} =
               Projections.Gmail.replay(owner: ctx.user, tenant: ctx.org)

      # The real gate, a declared zone, and an untagged account: refused.
      declare_test_zone(ctx.tmp_dir)

      assert {:ok, %{admitted: 0, messages: 0, denied_by: %{untagged_data_class: 2}}} =
               Projections.Gmail.replay(owner: ctx.user, tenant: ctx.org)

      # The operator tags the account; its records are admitted on those tags.
      tag_via_task!(ctx, account, "internal", "CA")

      assert {:ok, %{admitted: 2, denied: 0, messages: 2, conversations: 2}} =
               Projections.Gmail.replay(owner: ctx.user, tenant: ctx.org)

      messages = messages(ctx)
      assert Enum.all?(messages, &(&1.erasure_scope_id == scope.id))
      assert Enum.any?(messages, &(&1.body == "E2E-SYNTHETIC-BODY-1 the churn number"))
      assert Enum.all?(conversations(ctx), &(&1.erasure_scope_id == scope.id))
      assert Enum.all?(conversations(ctx), &(&1.owner_id == ctx.user.id))
      assert Enum.any?(conversations(ctx), &(&1.subject == "E2E-SYNTHETIC-SUBJECT-1"))
      assert_no_plaintext(content)

      shred_via_task!(ctx, account)

      assert Enum.all?(landed("gmail"), &Shredded.shredded?(&1.raw_payload))
      assert Enum.all?(messages(ctx), &Shredded.shredded?(&1.body))

      assert Enum.all?(
               conversations(ctx),
               &(Shredded.shredded?(&1.subject) and Shredded.shredded?(&1.participants))
             )

      assert_no_plaintext(content)

      # The documented gap (runbook, "Not reached"): a correspondent's Person
      # row outlives the shred -- owner-only, but not sealed.
      assert Person
             |> Ash.read!(tenant: ctx.org.id, authorize?: false)
             |> Enum.any?(&(to_string(&1.email) == "e2e.sender1@example.synthetic.test"))

      assert_no_audit_event_spells(content)

      assert {:ok, %{shredded: 2, admitted: 0, messages: 0}} =
               Projections.Gmail.replay(owner: ctx.user, tenant: ctx.org)

      requests_before = length(GmailSyntheticMailbox.requests(box))
      GmailSyntheticMailbox.add_message(box, body: "E2E-SYNTHETIC-AFTER-SHRED")

      assert {:cancel, :scope_shredded} = perform_job(Gmail.SyncWorker, job)
      assert length(GmailSyntheticMailbox.requests(box)) == requests_before
      assert length(landed("gmail")) == 2
      assert_no_plaintext(["E2E-SYNTHETIC-AFTER-SHRED" | content])
    end
  end

  # --- Slack ---------------------------------------------------------------------------

  describe "Slack" do
    @tag :tmp_dir
    test "sync, land, admit on the account's tags, project, shred: nothing readable is left",
         ctx do
      account = link_via_task!(ctx, "slack", "conn-slack-e2e-#{ctx.unique}")
      stub_slack()

      job = %{"user_id" => ctx.user.id, "linked_account_id" => account.id}
      assert :ok = perform_job(Slack.SyncWorker, job)

      scope = scope!(account)
      # A public channel, a private channel and a DM; five messages; two members.
      assert length(landed("slack")) == 10
      assert Enum.all?(landed("slack"), &(&1.erasure_scope_id == scope.id))

      # Deny by default: no gate wired, nothing projected.
      assert {:ok, %{admitted: 0, conversations: 0, messages: 0}} =
               Projections.Slack.replay(ctx.actor, account.id)

      # A zone, the real gate, and the operator's tags for the account.
      declare_test_zone(ctx.tmp_dir)
      tag_via_task!(ctx, account, "customer_confidential", "CA")

      assert {:ok, %{admitted: 10, denied: 0, conversations: 3, messages: 5}} =
               Projections.Slack.replay(ctx.actor, account.id)

      assert Enum.all?(conversations(ctx), &(&1.erasure_scope_id == scope.id))
      assert Enum.all?(conversations(ctx), &(&1.owner_id == ctx.user.id))

      assert conversations(ctx) |> Map.new(&{&1.kind, &1.subject}) == %{
               public_channel: "#e2e-synthetic-channel",
               private_channel: "#e2e-synthetic-private",
               dm: "E2E Synthetic Colleague"
             }

      assert Enum.all?(messages(ctx), &(&1.erasure_scope_id == scope.id))
      assert Enum.any?(messages(ctx), &(&1.body == "E2E-SYNTHETIC-SLACK-DM-1 salary figures"))
      assert Enum.any?(messages(ctx), &(&1.body == "E2E-SYNTHETIC-SLACK-1 VendorPM pricing"))
      assert_no_plaintext(slack_content())

      shred_via_task!(ctx, account)

      assert Enum.all?(landed("slack"), &Shredded.shredded?(&1.raw_payload))
      assert Enum.all?(messages(ctx), &Shredded.shredded?(&1.body))
      assert length(conversations(ctx)) == 3

      assert Enum.all?(
               conversations(ctx),
               &match?(%{subject: %Shredded{}, participants: %Shredded{}}, &1)
             )

      assert_no_plaintext(slack_content())
      assert_no_audit_event_spells(slack_content())

      assert {:ok, %{conversations: 0, messages: 0}} =
               Projections.Slack.replay(ctx.actor, account.id)

      tripwire()
      assert {:cancel, :scope_shredded} = perform_job(Slack.SyncWorker, job)
      refute_received {:provider_request, _path}
      assert length(landed("slack")) == 10
    end
  end

  # --- forgetting a linked account: the order ----------------------------------------

  describe "forgetting a linked account" do
    test "deactivate stops syncs, shred destroys content, unlink forgets the mapping", ctx do
      account = link_via_task!(ctx, "slack", "conn-slack-forget-#{ctx.unique}")
      stub_slack()
      job = %{"user_id" => ctx.user.id, "linked_account_id" => account.id}
      assert :ok = perform_job(Slack.SyncWorker, job)

      # 1. Deactivate: the scheduler stops enqueuing it and a queued step
      #    cancels without a request. Deactivating erases nothing.
      account
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: ctx.actor, tenant: ctx.org.id)
      |> Ash.update!()

      assert %{accounts: 0, enqueued: 0} = SyncScheduler.enqueue("slack")

      tripwire()
      assert {:cancel, :no_linked_account} = perform_job(Slack.SyncWorker, job)
      refute_received {:provider_request, _path}
      assert Enum.all?(landed("slack"), &is_map(&1.raw_payload))

      # 2. Shred (after deleting the Nango connection and revoking the app's
      #    tokens, which this test cannot reach): the content is gone.
      shred_via_task!(ctx, account)
      assert Enum.all?(landed("slack"), &Shredded.shredded?(&1.raw_payload))

      # 3. Unlink: the mapping is forgotten; the shredded scope remains as the
      #    tombstone, still named by the account's id.
      LinkedAccount.unlink!(account, actor: ctx.actor, tenant: ctx.org.id)

      assert {:ok, nil} =
               Ash.get(LinkedAccount, account.id, authorize?: false, not_found_error?: false)

      Mix.Tasks.AshEnterprise.Erasure.Scopes.run([])
      assert Enum.any?(collect_shell(), &(&1 =~ "connection:#{account.id}  shredded "))

      # The label the operator typed went nowhere permanent: not the audit
      # log, and the row that held it is gone.
      assert_no_audit_event_spells([ctx.label])
      assert_no_plaintext([ctx.label])
    end
  end

  # --- scheduling -------------------------------------------------------------------------

  describe "scheduling" do
    test "one step per active linked account per vertical; over-enqueueing collapses", ctx do
      cal = link_via_task!(ctx, "google-calendar", "conn-cal-sched-#{ctx.unique}")
      mail = link_via_task!(ctx, "google-mail", "conn-mail-sched-#{ctx.unique}")
      slack = link_via_task!(ctx, "slack", "conn-slack-sched-#{ctx.unique}")

      for integration <- SyncScheduler.integrations() do
        assert :ok = perform_job(SyncScheduler, %{"integration" => integration}) |> ok()
      end

      assert [%{args: %{"linked_account_id" => cal_id}}] =
               all_enqueued(worker: Calendar.SyncWorker)

      assert [%{args: %{"linked_account_id" => mail_id}}] = all_enqueued(worker: Gmail.SyncWorker)

      assert [%{args: %{"linked_account_id" => slack_id}}] =
               all_enqueued(worker: Slack.SyncWorker)

      assert {cal_id, mail_id, slack_id} == {cal.id, mail.id, slack.id}
      assert Enum.all?(all_enqueued(queue: :ingestion), &(&1.queue == "ingestion"))

      # A second tick while the steps are still queued enqueues nothing new.
      assert %{accounts: 1, enqueued: 0, already_enqueued: 1} = SyncScheduler.enqueue("slack")
      assert [_one] = all_enqueued(worker: Slack.SyncWorker)

      assert {:cancel, :unknown_integration} =
               perform_job(SyncScheduler, %{"integration" => "not-a-provider"})
    end
  end

  # --- blocked accounts ---------------------------------------------------------------------

  describe "an account that needs a person" do
    test "a revoked token blocks it until the operator unblocks it", ctx do
      account = link_via_task!(ctx, "slack", "conn-slack-revoked-#{ctx.unique}")

      Req.Test.stub(Proxy, fn conn ->
        send(self(), {:provider_request, conn.request_path})
        Req.Test.json(conn, %{"ok" => false, "error" => "token_revoked"})
      end)

      job = %{"user_id" => ctx.user.id, "linked_account_id" => account.id}
      assert {:cancel, :unauthorized} = perform_job(Slack.SyncWorker, job)
      assert blocked_reason(account) == "unauthorized"

      # Not polled again on every tick...
      assert %{accounts: 0, enqueued: 0} = SyncScheduler.enqueue("slack")

      # ...until someone re-links or fixes it and unblocks it.
      tripwire()

      Mix.Tasks.AshEnterprise.Integration.Sync.run([
        "--linked-account",
        account.id,
        "--unblock"
      ])

      assert "unblocked #{account.id}" in collect_shell()
      assert blocked_reason(account) == nil
      assert %{accounts: 1, enqueued: 1} = SyncScheduler.enqueue("slack")
    end

    test "an inactive owner's syncs cancel before any request, and the account is blocked",
         ctx do
      account = link_via_task!(ctx, "google-mail", "conn-mail-offboarded-#{ctx.unique}")

      ctx.user
      |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false)
      |> Ash.update!()

      tripwire()
      job = %{"user_id" => ctx.user.id, "linked_account_id" => account.id}
      assert {:cancel, :user_inactive} = perform_job(Gmail.SyncWorker, job)
      refute_received {:provider_request, _path}

      assert blocked_reason(account) == "user_inactive"
      assert %{accounts: 0} = SyncScheduler.enqueue("google-mail")
    end
  end

  # --- the operator tasks ----------------------------------------------------------------

  describe "operator tasks" do
    test "link never prints the connection id back in full and refuses unknown integrations",
         ctx do
      connection = "conn-secret-handle-#{ctx.unique}"
      account = link_via_task!(ctx, "slack", connection)

      assert account.connection_id == connection
      assert_accounts_task_lists(ctx, account, "active")

      assert_raise Mix.Error, ~r/--integration must be one of/, fn ->
        Mix.Tasks.AshEnterprise.Integration.Link.run([
          "--email",
          ctx.email,
          "--integration",
          "dropbox",
          "--connection-id",
          "x"
        ])
      end

      assert_raise Mix.Error, ~r/no user with email/, fn ->
        Mix.Tasks.AshEnterprise.Integration.Link.run([
          "--email",
          "nobody@e2e.synthetic.test",
          "--integration",
          "slack",
          "--connection-id",
          "x"
        ])
      end
    end

    test "sync prints a structural refusal for a deactivated account", ctx do
      account = link_via_task!(ctx, "google-mail", "conn-mail-paused-#{ctx.unique}")
      tripwire()

      account
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: ctx.actor, tenant: ctx.org.id)
      |> Ash.update!()

      Mix.Tasks.AshEnterprise.Integration.Sync.run([
        "--linked-account",
        account.id,
        "--steps",
        "3"
      ])

      assert_received {:mix_shell, :info, [line]}
      assert line == "step 1/3 google-mail status=cancelled reason=no_linked_account"
      refute_received {:mix_shell, :info, _}
      refute_received {:provider_request, _path}
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  defp blocked_reason(account) do
    Ash.get!(LinkedAccount, account.id, authorize?: false).sync_blocked_reason
  end

  defp ok({:ok, _summary}), do: :ok
  defp ok(other), do: other

  defp link_via_task!(ctx, integration, connection_id) do
    Mix.Tasks.AshEnterprise.Integration.Link.run([
      "--email",
      ctx.email,
      "--integration",
      integration,
      "--connection-id",
      connection_id,
      "--label",
      ctx.label
    ])

    assert_received {:mix_shell, :info, [output]}
    refute output =~ connection_id
    assert output =~ "connection ****" <> String.slice(connection_id, -4, 4)

    [_, id] = Regex.run(~r/account ([0-9a-f-]{36}) for/, output)
    assert output =~ "Erasure scope: connection:#{id} (active)"

    Ash.get!(LinkedAccount, id, tenant: ctx.org.id, authorize?: false)
  end

  defp assert_accounts_task_lists(ctx, account, status) do
    Mix.Tasks.AshEnterprise.Integration.Accounts.run(["--email", ctx.email])

    lines = collect_shell()
    line = Enum.find(lines, &String.starts_with?(&1, account.id))
    assert line, "accounts task did not list #{account.id}: #{inspect(lines)}"
    assert line =~ "scope connection:#{account.id} (#{status})"
    refute line =~ account.connection_id
  end

  defp shred_via_task!(ctx, account) do
    Mix.Tasks.AshEnterprise.Erasure.Shred.run([
      "connection:#{account.id}",
      "--as",
      ctx.email,
      "--reason",
      "e2e: forget this account",
      "--yes"
    ])

    _ = collect_shell()
    assert %Scope{status: :shredded} = scope!(account)
    assert_no_audit_event_spells([ctx.label])
  end

  defp collect_shell(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> collect_shell([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp scope!(account), do: Erasure.scope_by_ref!(:connection, account.id, authorize?: false)

  defp landed(system) do
    SourceObject
    |> Ash.Query.filter(external_system == ^system)
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false)
  end

  defp calendar_events(ctx), do: CalendarEvent.read!(tenant: ctx.org.id, authorize?: false)
  defp messages(ctx), do: Message.read!(tenant: ctx.org.id, authorize?: false)
  defp conversations(ctx), do: Conversation.read!(tenant: ctx.org.id, authorize?: false)

  # Every table a sync, a projection or a job writes content-bearing data to,
  # read raw. `canonical_people` is deliberately not here: a correspondent's
  # name and email are not sealed (runbook, "Not reached"), and the test below
  # says so rather than pretending otherwise.
  @swept_tables ~w(ingestion_source_objects canonical_calendar_events canonical_messages
                   canonical_conversations integration_linked_accounts erasure_scopes
                   integration_calendar_sync_cursors integration_gmail_sync_states
                   integration_slack_conversation_cursors integration_slack_known_members
                   oban_jobs)

  # `cursor_exempt`: strings the calendar sync cursor may still hold (its
  # calendar ids) until the linked account is unlinked.
  defp assert_no_plaintext(strings, cursor_exempt \\ []) do
    for table <- @swept_tables do
      %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t")
      text = rows |> List.flatten() |> Enum.join("\n")

      expected =
        if table == "integration_calendar_sync_cursors",
          do: strings -- cursor_exempt,
          else: strings

      refute_spells(text, expected, table)
    end

    assert_no_audit_event_spells(strings)
  end

  defp calendar_ids, do: [F.primary_calendar(), F.team_calendar()]

  # The whole audit log, every column, as stored.
  defp assert_no_audit_event_spells(strings) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(e)::text FROM audit_events e")
    assert rows != []
    refute_spells(rows |> List.flatten() |> Enum.join("\n"), strings, "audit_events")
  end

  defp refute_spells(text, strings, where \\ "output") do
    for string <- strings do
      refute String.contains?(text, string), "#{where} spells #{inspect(string)}"
    end
  end

  # --- provider stubs -------------------------------------------------------------------------

  # Any provider request from here on is a failure; requests made before it
  # (the sync being shredded) are drained first.
  defp tripwire do
    test_pid = self()
    drain_provider_requests()

    Req.Test.stub(Proxy, fn conn ->
      send(test_pid, {:provider_request, conn.request_path})
      Plug.Conn.send_resp(conn, 500, "")
    end)
  end

  defp drain_provider_requests do
    receive do
      {:provider_request, _path} -> drain_provider_requests()
    after
      0 -> :ok
    end
  end

  defp stub_calendar do
    test_pid = self()

    Req.Test.stub(Proxy, fn conn ->
      send(test_pid, {:provider_request, conn.request_path})

      case conn.request_path do
        "/proxy/calendar/v3/users/me/calendarList" ->
          Req.Test.json(conn, F.calendar_list([F.primary_calendar()]))

        "/proxy/calendar/v3/calendars/" <> _calendar ->
          Req.Test.json(
            conn,
            F.events_page(
              [F.planning_event(), F.review_event(), F.offsite_event()],
              {:sync, "sync-e2e-1"}
            )
          )
      end
    end)
  end

  @channel "C0E2ESYNTH"
  @private_channel "C0E2ESYNTHPRV"
  @dm "D0E2ESYNTH"
  @self_user "U0E2ESELF"
  @other_user "U0E2EOTHER"

  defp slack_content do
    [
      "E2E-SYNTHETIC-SLACK-1 VendorPM pricing",
      "E2E-SYNTHETIC-SLACK-2 contract terms",
      "E2E-SYNTHETIC-SLACK-DM-1 salary figures",
      "E2E-SYNTHETIC-SLACK-DM-2 offer letter",
      "E2E-SYNTHETIC-SLACK-PRV-1 board notes",
      "e2e-synthetic-channel",
      "e2e-synthetic-private",
      "E2E Synthetic Colleague",
      "colleague.e2e@example.synthetic.test"
    ]
  end

  defp stub_slack do
    test_pid = self()
    now = DateTime.utc_now()
    ts = fn hours -> Records.datetime_to_ts(DateTime.add(now, -hours * 3600, :second)) end

    channel = %{
      "id" => @channel,
      "name" => "e2e-synthetic-channel",
      "is_channel" => true,
      "is_private" => false,
      "is_archived" => false,
      "is_member" => true
    }

    private_channel = %{
      "id" => @private_channel,
      "name" => "e2e-synthetic-private",
      "is_channel" => true,
      "is_private" => true,
      "is_archived" => false,
      "is_member" => true
    }

    dm = %{"id" => @dm, "is_im" => true, "user" => @other_user}

    message = fn user, text, hours ->
      %{"type" => "message", "user" => user, "text" => text, "ts" => ts.(hours)}
    end

    messages = %{
      @channel => [
        message.(@other_user, "E2E-SYNTHETIC-SLACK-2 contract terms", 1),
        message.(@self_user, "E2E-SYNTHETIC-SLACK-1 VendorPM pricing", 2)
      ],
      @dm => [
        message.(@self_user, "E2E-SYNTHETIC-SLACK-DM-2 offer letter", 3),
        message.(@other_user, "E2E-SYNTHETIC-SLACK-DM-1 salary figures", 4)
      ],
      @private_channel => [message.(@other_user, "E2E-SYNTHETIC-SLACK-PRV-1 board notes", 5)]
    }

    users = %{
      @self_user =>
        slack_user(@self_user, "E2E Synthetic Self", "self.e2e@example.synthetic.test"),
      @other_user =>
        slack_user(@other_user, "E2E Synthetic Colleague", "colleague.e2e@example.synthetic.test")
    }

    Req.Test.stub(Proxy, fn conn ->
      send(test_pid, {:provider_request, conn.request_path})
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        case conn.request_path do
          "/proxy/conversations.list" ->
            %{
              "ok" => true,
              "channels" => [channel, private_channel, dm],
              "response_metadata" => %{"next_cursor" => ""}
            }

          "/proxy/conversations.history" ->
            %{
              "ok" => true,
              "messages" => Map.get(messages, conn.query_params["channel"], []),
              "has_more" => false,
              "response_metadata" => %{"next_cursor" => ""}
            }

          "/proxy/users.info" ->
            %{"ok" => true, "user" => Map.fetch!(users, conn.query_params["user"])}
        end

      Req.Test.json(conn, body)
    end)
  end

  defp slack_user(id, name, email) do
    %{
      "id" => id,
      "team_id" => "T0E2ESYNTH",
      "name" => String.downcase(name),
      "real_name" => name,
      "deleted" => false,
      "is_bot" => false,
      "profile" => %{"real_name" => name, "display_name" => name, "email" => email}
    }
  end

  defp gmail_content do
    [
      "E2E-SYNTHETIC-SUBJECT-1",
      "E2E-SYNTHETIC-SUBJECT-2",
      "E2E-SYNTHETIC-BODY-1 the churn number",
      "E2E-SYNTHETIC-BODY-2 the churn number",
      "E2E Synthetic Sender",
      "e2e.sender1@example.synthetic.test"
    ]
  end

  # A zone for the test only, declared as the canonical store's, with the
  # real gate on both projections. The default remains deny.
  defp declare_test_zone(tmp_dir) do
    today = Date.utc_today()

    path = Path.join(tmp_dir, "e2e-slack-zone.json")

    File.write!(
      path,
      Jason.encode!(%{
        "id" => "e2e-slack-zone",
        "jurisdiction" => "CA-ON",
        "classification_ceiling" => "customer_confidential",
        "inadmissible_restrictions" => ["US"],
        "declared_by" => "Test Operator",
        "declared_at" => Date.to_iso8601(Date.add(today, -1)),
        "review_by" => Date.to_iso8601(Date.add(today, 30))
      })
    )

    Application.put_env(:ash_enterprise, AshEnterprise.Zones, declarations: [path])

    Application.put_env(:ash_enterprise, Projections.ZoneAdmission, zone: "e2e-slack-zone")
    Application.put_env(:ash_enterprise, Projections.Gmail, zone_gate: Projections.ZoneAdmission)
    Application.put_env(:ash_enterprise, Projections.Slack, zone_gate: Projections.ZoneAdmission)
  end

  # The operator's tags for an account, through the operator task.
  defp tag_via_task!(ctx, account, data_class, residency) do
    Mix.Tasks.AshEnterprise.Integration.Tag.run([
      "--email",
      ctx.email,
      "--linked-account",
      account.id,
      "--data-class",
      data_class,
      "--residency",
      residency
    ])

    assert_received {:mix_shell, :info, [line]}
    assert line =~ "data_class=#{data_class} residency=#{residency}"
  end
end
