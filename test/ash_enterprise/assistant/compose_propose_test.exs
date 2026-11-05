defmodule AshEnterprise.Assistant.ComposeProposeTest do
  @moduledoc """
  The assistant's composer and the changes it may ask for (E10.3, E10.4) on
  synthetic data: what a composed spec may name, that its rows are read as the
  person, that a change it asks for is a governed invocation (ADR 0055) that changes
  nothing until the person confirms it and then runs as them, and that pinned apps
  and drafts are their owner's alone.
  """

  use AshEnterprise.DataCase, async: false

  alias AshAgent.Run.Toolset
  alias AshEnterprise.Assistant.{Composer, PinnedApp, ReplyDraft, Requests}
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Execution
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.DailyFixtures, as: D

  setup do
    F.in_zone!()
    F.tenant!()
  end

  # A tool's one row, as the model reads it, run as a run's step runs it.
  defp tool!(ctx, name, input), do: ctx |> F.tool!(name, input) |> hd()

  # What a run's call to `target` asks for, requested as the person.
  defp request!(ctx, target, args) do
    Execution.invoke!(
      "AshEnterprise." <> target,
      args,
      %{key: "assistant-test:#{Ash.UUID.generate()}"},
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  # Confirmed, or refused before it could be: what became of it.
  defp decided(ctx, %{status: :awaiting_approval} = request) do
    {:ok, row} = Requests.confirm(request.id, ctx.actor, ctx.tenant)
    row
  end

  defp decided(_ctx, request), do: request

  defp encoded(surface, ctx),
    do:
      surface
      |> AshA2ui.Dynamic.build_surface(actor: ctx.actor, tenant: ctx.tenant)
      |> Jason.encode!()

  describe "the composer" do
    test "writes a verified table, calendar and board for every source it offers", ctx do
      for show <- Composer.sources(), display <- ~w(table calendar board) do
        case {show, display, Composer.compose(%{show: show, display: display})} do
          {_, _, {:ok, composed}} ->
            assert %AshA2ui.Dynamic.Surface{} = composed.surface
            assert composed.spec["resource"] == show
            refute Enum.any?(composed.spec["components"], &Map.has_key?(&1, "row_actions"))
            # ...and it builds, as the person, without a row action anywhere.
            assert [_ | _] =
                     AshA2ui.Dynamic.build_surface(composed.surface,
                       actor: ctx.actor,
                       tenant: ctx.tenant
                     )

          {show, display, {:error, [reason | _]}} ->
            # Only the combinations the catalogue cannot place are refused,
            # with a reason the model can act on.
            assert display in ~w(calendar board), "#{show} #{display}: #{reason}"
            assert reason =~ "use a table"
        end
      end
    end

    test "refuses what it cannot show with short reasons, and notes what it ignored" do
      assert {:error, [reason]} = Composer.compose(%{show: "secrets"})
      assert reason =~ "show must be one of"

      assert {:error, [reason]} =
               Composer.compose(%{show: "tasks", display: "board", group_by: "title"})

      assert reason =~ "splits by status"

      assert {:ok, composed} =
               Composer.compose(%{
                 show: "tasks",
                 columns: ["title", "SYNTHETIC-nope"],
                 status: :open
               })

      assert [note] = composed.notes
      assert note =~ "SYNTHETIC-nope"
      assert composed.spec["components"] |> hd() |> Map.fetch!("fields") == ["title"]
    end

    test "builds as the person: their rows, and nobody else's", ctx do
      bob = F.colleague!(ctx, admin?: true)
      D.conversation!(ctx, "gmail", "SYNTHETIC alice standup", "hi")

      D.conversation!(
        %{user: bob.user, tenant: ctx.tenant},
        "gmail",
        "SYNTHETIC bob private",
        "hi"
      )

      # Conversations are owner-only: even the tenant's Administrator (alice)
      # reads only her own.
      {:ok, composed} = Composer.compose(%{show: "conversations", channel: "gmail"})
      json = encoded(composed.surface, ctx)

      assert json =~ "SYNTHETIC alice standup"
      refute json =~ "SYNTHETIC bob private"
    end

    test "the compose tool answers the model without rows, and is zone-gated", ctx do
      D.event!(ctx, "SYNTHETIC tool row", 60, 30)

      result =
        tool!(ctx, :compose_surface, %{
          show: :events,
          display: :calendar
        })

      assert result["surface"]["show"] == "events"
      assert result["shown"] =~ "Calendar events"
      refute Jason.encode!(result) =~ "SYNTHETIC tool row"

      assert F.refusal(ctx, :compose_surface, %{show: :events}, run?: false) =~ "ADR 0042"
    end
  end

  describe "days" do
    # Minutes from now to `hour`:00 on `date`, on the display zone's clock.
    defp minutes_to(date, hour) do
      {midnight, _} = LocalTime.days(date, 1)
      midnight |> DateTime.add(hour, :hour) |> DateTime.diff(DateTime.utc_now(), :minute)
    end

    defp coming_monday do
      today = LocalTime.today()
      Date.add(today, rem(8 - Date.day_of_week(today), 7))
    end

    test "a weekday is the coming one, today included; next_week is Monday to Sunday" do
      today = LocalTime.today()
      monday = coming_monday()

      assert {:ok, ^monday, ^monday} = Support.days("monday")
      assert {:ok, ^monday, ^monday} = Support.days("  Monday ")
      assert {:ok, ^monday, ^monday} = Support.days("mon")
      assert {:ok, ^today, ^today} = Support.days(today |> Calendar.strftime("%A"))

      next_monday = Date.add(today, 8 - Date.day_of_week(today))
      next_sunday = Date.add(next_monday, 6)
      assert {:ok, ^next_monday, ^next_sunday} = Support.days("next week")
      assert Date.day_of_week(next_monday) == 1 and Date.compare(next_monday, today) == :gt

      assert Support.days("upcoming") == :not_days
      assert Support.days(nil) == :none
      assert {:error, message} = Support.days("SYNTHETIC-someday")
      assert message =~ "weekday"

      # The read tools take the same windows.
      assert {:ok, {from, to}} = Support.window("monday")
      assert {from, to} == LocalTime.days(monday, 1)
    end

    test "Monday's events: a day calendar opened on the coming Monday, as the person", ctx do
      monday = coming_monday()
      D.event!(ctx, "SYNTHETIC monday review", minutes_to(monday, 15), 30)
      D.event!(ctx, "SYNTHETIC tuesday after", minutes_to(Date.add(monday, 1), 15), 30)

      {:ok, composed} = Composer.compose(%{show: "events", display: "calendar", window: "monday"})

      assert [%{"granularity" => "day", "query" => query}] = composed.spec["components"]
      assert [%{"name" => ^query}] = composed.spec["queries"]
      assert composed.query_state == %{"window" => %{"anchor" => Date.to_iso8601(monday)}}
      assert composed.covers == LocalTime.day(monday)
      assert composed.title =~ composed.covers

      json =
        composed.surface
        |> AshA2ui.Dynamic.build_surface(
          Composer.build_opts(composed, actor: ctx.actor, tenant: ctx.tenant)
        )
        |> Jason.encode!()

      assert json =~ "SYNTHETIC monday review"
      refute json =~ "SYNTHETIC tuesday after"
    end

    test "a table of next week's events is cut by a range on its start", ctx do
      today = LocalTime.today()
      next_monday = Date.add(today, 8 - Date.day_of_week(today))

      D.event!(ctx, "SYNTHETIC next week qbr", minutes_to(Date.add(next_monday, 2), 11), 60)
      D.event!(ctx, "SYNTHETIC before next week", minutes_to(Date.add(next_monday, -1), 11), 60)
      D.event!(ctx, "SYNTHETIC after next week", minutes_to(Date.add(next_monday, 7), 11), 60)

      {:ok, composed} = Composer.compose(%{show: "events", display: "table", window: "next_week"})

      assert [%{"range_filters" => ["starts_at"]}] = composed.spec["queries"]
      assert %{"ranges" => %{"starts_at" => %{"from" => from, "to" => to}}} = composed.query_state
      assert from =~ Date.to_iso8601(next_monday)
      assert to =~ Date.to_iso8601(Date.add(next_monday, 6))
      # The spec carries no date: the range is the table's initial state.
      refute AshA2ui.Dynamic.serialize(composed.surface) =~ Date.to_iso8601(next_monday)

      json =
        composed.surface
        |> AshA2ui.Dynamic.build_surface(
          Composer.build_opts(composed, actor: ctx.actor, tenant: ctx.tenant)
        )
        |> Jason.encode!()

      assert json =~ "SYNTHETIC next week qbr"
      refute json =~ "SYNTHETIC before next week"
      refute json =~ "SYNTHETIC after next week"
    end

    test "named windows keep the windowed read; an unknown window is refused for the model" do
      {:ok, composed} = Composer.compose(%{show: "events", window: "tomorrow"})
      assert [%{"read_action" => "tomorrow"}] = composed.spec["components"]
      assert composed.query_state == nil

      {:ok, calendar} =
        Composer.compose(%{show: "events", display: "calendar", window: "tomorrow"})

      tomorrow = Date.add(LocalTime.today(), 1)
      assert calendar.query_state == %{"window" => %{"anchor" => Date.to_iso8601(tomorrow)}}

      assert {:error, [reason]} = Composer.compose(%{show: "events", window: "SYNTHETIC-soon"})
      assert reason =~ "window:"
      refute reason =~ "Declare"
    end

    test "the compose tool tells the model which days it showed", ctx do
      result =
        tool!(ctx, :compose_surface, %{
          show: :events,
          display: :calendar,
          window: "monday"
        })

      assert result["covers"] == LocalTime.day(coming_monday())
      assert result["surface"]["window"] == "monday"
    end
  end

  describe "requests" do
    test "the model names each change as the assistant declares it" do
      assert Toolset.tool_name(Task, :capture) == "add_action_item"
      assert Toolset.tool_name(Task, :complete_mine) == "finish_action_item"
      assert Toolset.tool_name(ReplyDraft, :draft) == "draft_reply"
      assert Toolset.tool_name(LinkedAccount, :sync_now) == "sync_account"
    end

    test "finish an action item: nothing until confirmed, then as the person", ctx do
      {:ok, task} =
        Task.capture("SYNTHETIC send the deck", %{}, actor: ctx.actor, tenant: ctx.tenant)

      request = request!(ctx, "Canonical.Task.complete_mine", %{"record_id" => task.id})
      assert request.status == :awaiting_approval

      assert %{kind: :finish_action_item, title: "SYNTHETIC send the deck"} =
               Requests.describe(request, ctx.actor, ctx.tenant)

      assert [%{status: :open}] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)

      assert %{status: :succeeded} = decided(ctx, request)
      assert [%{status: :done}] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)
    end

    test "another person's task or conversation is never touched", ctx do
      bob = F.colleague!(ctx, admin?: true)

      {:ok, bobs} =
        Task.capture("SYNTHETIC bob's item", %{}, actor: bob.actor, tenant: ctx.tenant)

      request = request!(ctx, "Canonical.Task.complete_mine", %{"record_id" => bobs.id})
      assert decided(ctx, request).status in [:rejected, :failed]
      assert [%{status: :open}] = Task.mine!(actor: bob.actor, tenant: ctx.tenant)

      conversation =
        D.conversation!(
          %{user: bob.user, tenant: ctx.tenant},
          "gmail",
          "SYNTHETIC bob mail",
          "hi"
        )

      request =
        request!(ctx, "Assistant.ReplyDraft.draft", %{
          "conversation_id" => conversation.id,
          "body" => "SYNTHETIC reply"
        })

      assert decided(ctx, request).status in [:rejected, :failed]
      assert Ash.read!(ReplyDraft, authorize?: false, tenant: ctx.tenant) == []
    end

    test "a reply draft is stored, sealed and owner-only, never sent", ctx do
      conversation = D.conversation!(ctx, "gmail", "SYNTHETIC launch", "Can you confirm?")

      request =
        request!(ctx, "Assistant.ReplyDraft.draft", %{
          "conversation_id" => conversation.id,
          "body" => "SYNTHETIC: confirmed for Friday."
        })

      assert %{kind: :draft_reply, subject: "SYNTHETIC launch", body: body} =
               Requests.describe(request, ctx.actor, ctx.tenant)

      assert body == "SYNTHETIC: confirmed for Friday."
      assert ReplyDraft.mine!(actor: ctx.actor, tenant: ctx.tenant) == []

      assert %{status: :succeeded} = decided(ctx, request)

      [mine] = ReplyDraft.mine!(actor: ctx.actor, tenant: ctx.tenant)
      assert mine.body == "SYNTHETIC: confirmed for Friday."
      assert mine.erasure_scope_id == conversation.erasure_scope_id

      # Ciphertext at rest, and nobody else's to read.
      [%{encrypted_body: ciphertext}] =
        Ash.read!(ReplyDraft, authorize?: false, tenant: ctx.tenant)

      refute ciphertext =~ "confirmed for Friday"

      bob = F.colleague!(ctx, admin?: true)
      assert ReplyDraft.mine!(actor: bob.actor, tenant: ctx.tenant) == []
      assert Ash.read!(ReplyDraft, actor: bob.actor, tenant: ctx.tenant) == []
    end

    test "sync names one of the person's linked accounts", ctx do
      assert F.tool!(ctx, :my_accounts, %{}) == []

      account = D.linked_account!(ctx, "google-mail")

      assert [%{"id" => id, "provider" => "Gmail"}] = F.tool!(ctx, :my_accounts, %{})
      assert id == account.id

      request = request!(ctx, "Integration.LinkedAccount.sync_now", %{"record_id" => account.id})

      assert %{kind: :sync_account, account: "Gmail"} =
               Requests.describe(request, ctx.actor, ctx.tenant)

      assert %{status: :succeeded} = decided(ctx, request)
    end
  end

  describe "pinned apps" do
    test "pin, re-verify on load, owner-only, unpin", ctx do
      {:ok, composed} = Composer.compose(%{show: "tasks", display: "board"})
      spec = AshA2ui.Dynamic.serialize(composed.surface)

      {:ok, app} =
        PinnedApp.pin(
          %{
            title: Composer.structural_title(composed.request),
            display: :board,
            source: "tasks",
            spec: spec
          },
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      assert app.title == "Tasks · board"
      assert {:ok, %AshA2ui.Dynamic.Surface{}} = Composer.reload(app.spec)
      assert {:error, [_ | _]} = Composer.reload(String.replace(spec, "\"tasks\"", "\"secrets\""))

      bob = F.colleague!(ctx, admin?: true)
      assert PinnedApp.mine!(actor: bob.actor, tenant: ctx.tenant) == []
      assert {:error, _} = PinnedApp.get(app.id, actor: bob.actor, tenant: ctx.tenant)
      assert {:error, _} = PinnedApp.unpin(app.id, actor: bob.actor, tenant: ctx.tenant)

      assert :ok = PinnedApp.unpin(app.id, actor: ctx.actor, tenant: ctx.tenant)
      assert PinnedApp.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
    end
  end
end
