defmodule AshEnterprise.DailyLoopTest do
  @moduledoc """
  The reads and the few decisions behind the daily-loop surfaces (Today,
  Calendar, Inbox, Slack, People, Approvals, Accounts, Erasure): agenda windows
  in the display zone, digests, the empty-inbox explanations, approvals decided
  through the process engine only by a candidate, and the operator-only
  erasure read. Everything runs as a real seeded actor under real policies.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Agents.{BriefDecision, Console, Today}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.{Admission, CalendarEvent, Conversation, Person}
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime

  defp opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]

  describe "agenda windows" do
    test "today, tomorrow and this week cut in the display zone, in start order" do
      ctx = tenant!()
      {_, today_end} = LocalTime.window(:today)
      minutes_left = div(DateTime.diff(today_end, DateTime.utc_now(), :second), 60)

      later = event!(ctx, "Later today", min(30, minutes_left - 10), 5)
      tomorrow = event!(ctx, "Tomorrow thing", minutes_left + 60, 30)
      next_week = event!(ctx, "Far away", 60 * 24 * 10, 30)

      today = CalendarEvent |> Ash.Query.for_read(:today, %{}, opts(ctx)) |> Ash.read!()
      assert Enum.map(today, & &1.id) == [later.id]

      assert [%{id: id}] =
               CalendarEvent |> Ash.Query.for_read(:tomorrow, %{}, opts(ctx)) |> Ash.read!()

      assert id == tomorrow.id

      week = CalendarEvent |> Ash.Query.for_read(:this_week, %{}, opts(ctx)) |> Ash.read!()
      assert Enum.map(week, & &1.id) == [later.id, tomorrow.id]
      refute next_week.id in Enum.map(week, & &1.id)
    end

    test "the digest is the window's rows as text, cancellations marked" do
      ctx = tenant!()
      event!(ctx, "Standup", 1, 15, location: "Zoom")
      event!(ctx, "Retro", 2, 30, status: :cancelled)

      assert {:ok, text} = Console.agenda(:today, opts(ctx))
      assert text =~ "Today ·"
      assert text =~ "2 events"
      assert text =~ "Standup  · Zoom"
      assert text =~ "Retro  [cancelled]"
    end

    test "another tenant's events never appear" do
      ctx = tenant!()
      other = tenant!()
      event!(other, "Not yours", 5, 10)

      assert {:ok, text} = Console.agenda(:today, opts(ctx))
      assert text =~ "nothing scheduled"
    end
  end

  describe "people" do
    test "the directory digest searches by name or address and counts their events" do
      ctx = tenant!()
      event!(ctx, "Planning", 10, 30, organizer: {"ada@example.test", "Ada Park"})
      person!(ctx, "grace@example.test", "Grace Hopper")

      assert {:ok, text} = Console.people("ada", opts(ctx))
      assert text =~ "Ada Park  <ada@example.test>  · 1 events"
      refute text =~ "Grace"

      [ada] =
        Person
        |> Ash.Query.for_read(:read, %{}, opts(ctx))
        |> Ash.Query.filter(email == "ada@example.test")
        |> Ash.Query.load([:next_event, :organized_event_count])
        |> Ash.read!()

      assert ada.organized_event_count == 1
      assert ada.next_event =~ "Planning"

      assert %{organized_events: [%{title: "Planning"}]} =
               Ash.load!(ada, :organized_events, opts(ctx))
    end
  end

  describe "inbox and Slack" do
    test "an empty inbox says it is held back by the zone gate, not that there is no mail" do
      ctx = tenant!()

      assert Admission.held?(:gmail)
      assert {:ok, text} = Console.inbox(:gmail, opts(ctx))
      assert text =~ "no conversations"
      assert text =~ "held back until zone admission (ADR 0042)"

      assert {:ok, slack} = Console.inbox(:slack, opts(ctx))
      assert slack =~ "held back until zone admission (ADR 0042)"
    end

    test "once admitted, the empty states tell a linked account from no account" do
      assert Admission.empty_message(:gmail, false) =~ "held back"

      admitted = fn ->
        Application.put_env(:ash_enterprise, AshEnterprise.Canonical.Projections.Gmail,
          zone_gate: __MODULE__.AdmitAll
        )
      end

      admitted.()

      on_exit(fn ->
        Application.delete_env(:ash_enterprise, AshEnterprise.Canonical.Projections.Gmail)
      end)

      assert Admission.empty_message(:gmail, true) =~
               "Nothing has been admitted from your Gmail account yet"

      assert Admission.empty_message(:gmail, false) =~ "No Gmail account is linked"
    end

    test "Slack conversations are labelled by kind, and tolerate a source that does not say" do
      alias AshEnterprise.Canonical.Calculations.ConversationKind

      assert ConversationKind.label(%{external_system: "slack"}) == "Conversation"
      assert ConversationKind.label(%{external_system: "gmail"}) == "Thread"
      assert ConversationKind.label(%{external_system: "slack", kind: :dm}) == "DM"

      assert ConversationKind.label(%{external_system: "slack", kind: "private_channel"}) ==
               "Private channel"

      ctx = tenant!()
      conversation!(ctx, "slack", "#eng", "Deploy is green")

      [row] =
        Conversation
        |> Ash.Query.for_read(:slack, %{}, opts(ctx))
        |> Ash.Query.load(:kind_label)
        |> Ash.read!()

      assert row.kind_label in ["Conversation", "Channel"]
    end

    test "conversations list newest first, per vertical, with their latest message" do
      ctx = tenant!()
      conversation!(ctx, "gmail", "Quarterly review", "Can we move it to Thursday?")
      conversation!(ctx, "slack", "#eng", "Deploy is green")

      [thread] =
        Conversation
        |> Ash.Query.for_read(:gmail, %{}, opts(ctx))
        |> Ash.Query.load([:latest_message, :message_count])
        |> Ash.read!()

      assert thread.subject == "Quarterly review"
      assert thread.message_count == 1
      assert thread.latest_message == "Sender: Can we move it to Thursday?"

      # The detail's related table reads the thread's messages, senders linked.
      assert %{messages: [message]} =
               Ash.load!(thread, [messages: [:sender_label, :preview]], opts(ctx))

      assert message.sender_label == "Sender"
      assert message.preview == "Can we move it to Thursday?"

      assert {:ok, text} = Console.inbox(:slack, opts(ctx))
      assert text =~ "#eng"
      refute text =~ "Quarterly review"
    end
  end

  describe "approvals" do
    test "the brief's approval task is waiting on its owner and decides through the engine" do
      ctx = tenant!()
      event!(ctx, "Design review", 5, 30)
      brief = brief!(ctx)

      [task] = HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()

      [task] = Ash.load!([task], [:subject_label, :subject_outline, :subject_detail], opts(ctx))
      assert task.subject_label =~ "Morning brief ·"
      assert task.subject_outline =~ "1 event"
      assert task.subject_detail =~ "Design review"

      assert {:ok, digest} = Console.approvals(opts(ctx))
      assert digest =~ "1. Approve the brief — Morning brief"

      assert {:ok, "Approved — Approve the brief."} =
               HumanTask
               |> Ash.ActionInput.for_action(:approve, %{record_id: task.id}, opts(ctx))
               |> Ash.run_action()

      assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
      assert [] == HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()
    end

    test "someone who is not a candidate cannot decide the task" do
      ctx = tenant!()
      brief!(ctx)
      [task] = HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()

      # Another administrator in the same tenant: may read the task, is not
      # its candidate (the brief's owner is).
      {:ok, other_user} =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "other-#{System.unique_integer([:positive])}@example.test",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create()

      other = actor(other_user)

      assert {:error, _} =
               HumanTask
               |> Ash.ActionInput.for_action(:reject, %{record_id: task.id},
                 actor: other,
                 tenant: ctx.tenant
               )
               |> Ash.run_action()

      assert [%{status: :open}] =
               HumanTask |> Ash.Query.for_read(:awaiting_me, %{}, opts(ctx)) |> Ash.read!()
    end

    test "Today's Approve goes through the brief's task, never the brief directly" do
      ctx = tenant!()
      brief = brief!(ctx)

      assert {:ok, _} =
               BriefDecision.decide(
                 %{record: brief, actor: ctx.actor, tenant: ctx.tenant},
                 "rejected"
               )

      assert %{status: :rejected} = reload_brief!(brief, ctx.tenant)

      # Decided: nothing is waiting any more, so a second click is refused.
      assert {:error, %Ash.Error.Changes.InvalidArgument{}} =
               BriefDecision.decide(
                 %{
                   record: reload_brief!(brief, ctx.tenant),
                   actor: ctx.actor,
                   tenant: ctx.tenant
                 },
                 "approved"
               )
    end
  end

  describe "today" do
    test "the digest leads with the agenda, then the brief, then the pulse" do
      ctx = tenant!()
      event!(ctx, "Focus block", 3, 60)
      brief!(ctx)
      linked_account!(ctx, "google-calendar")

      assert {:ok, text} = Console.today(opts(ctx))
      assert text =~ "Focus block"
      assert text =~ "Morning brief for"
      assert text =~ "say `approve brief`"
      assert text =~ "Approvals: 1 waiting"
      assert text =~ "Google Calendar sync: Not synced yet"
      assert text =~ "Inbox: held back until zone admission (ADR 0042)"

      assert {:ok, [%{signal: "Approvals"} | _]} = Today.pulse(opts(ctx))
    end
  end

  describe "accounts and syncs" do
    test "health is structure only, and sync now goes through the vertical's own request_sync" do
      ctx = tenant!()
      account = linked_account!(ctx, "google-calendar")

      [row] =
        LinkedAccount
        |> Ash.Query.for_read(:read, %{}, opts(ctx))
        |> Ash.Query.filter(provider_config_key == "google-calendar")
        |> Ash.Query.load([:provider, :health, :last_sync, :reach, :blocked])
        |> Ash.read!()

      assert %{provider: "Google Calendar", health: "Not synced yet", last_sync: "never"} = row

      gmail = linked_account!(ctx, "google-mail")

      assert %{projection: "Not projected yet"} =
               Ash.load!(gmail, :projection, opts(ctx))

      refute row.blocked

      assert {:ok, "Google Calendar sync queued."} = LinkedAccount.sync_now(account.id, opts(ctx))

      assert [%Oban.Job{args: %{"linked_account_id" => id}}] =
               all_enqueued(worker: AshEnterprise.Integration.Calendar.SyncWorker)

      assert id == account.id

      assert {:ok, digest} = Console.accounts(opts(ctx))
      assert digest =~ "Google Calendar  · Not synced yet"
      refute digest =~ "synthetic-"
    end
  end

  describe "erasure scopes" do
    test "the digest is operator-only" do
      operator = tenant!(operator?: true)
      admin = tenant!()
      scope!("test:digest-scope")

      assert {:ok, text} = Scope.scopes_digest(opts(operator))
      assert text =~ "test:digest-scope"

      assert {:error, %Ash.Error.Forbidden{}} = Scope.scopes_digest(opts(admin))
    end
  end

  defmodule AdmitAll do
    @moduledoc false
    def admit(_source, _context), do: :ok
  end
end
