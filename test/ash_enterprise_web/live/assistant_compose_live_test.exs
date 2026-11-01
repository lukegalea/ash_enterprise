defmodule AshEnterpriseWeb.AssistantComposeLiveTest do
  @moduledoc """
  `/app/agent` composing and proposing (E10.3, E10.4) through the real
  LiveView: a composed board renders inline as the person and pins into "My
  apps" on the launcher, where it opens (re-verified) and unpins; a proposal
  waits for Confirm and then runs as the person. Each answer is a run of the
  assistant agent, stepped here as its jobs would step it; a scripted model
  stands in for the in-zone runtime; every row is synthetic.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Assistant.{History, PinnedApp, Thread, Turn}
  alias AshEnterprise.Bpmn.{HumanTask, TaskCandidate}
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.DailyFixtures, as: D
  alias AshEnterpriseWeb.AssistantHandoff

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp await_answer(view, selector \\ "#turns article") do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      if not has_element?(view, "#live-turn") and has_element?(view, selector) do
        {:halt, render(view)}
      else
        _ = :sys.get_state(view.pid)

        receive do
        after
          50 -> {:cont, nil}
        end
      end
    end) || flunk("no answer rendered: " <> render(view))
  end

  # The page's runs, run out here as their jobs would run them.
  defp run_out!(ctx) do
    for run <- Execution.list_agent_runs!(authorize?: false, tenant: ctx.tenant),
        do: F.run_out!(run)
  end

  defp ask(view, ctx, question) do
    view |> form("#ask-form", ask: %{question: question}) |> render_submit()
    run_out!(ctx)
    await_answer(view)
  end

  setup %{conn: conn} do
    F.in_zone!()
    ctx = F.tenant!()
    F.published!(ctx)
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  test "a composed board renders inline, pins into My apps, opens and unpins",
       %{conn: conn, ctx: ctx} do
    {:ok, _} =
      Task.capture("SYNTHETIC water the plants", %{}, actor: ctx.actor, tenant: ctx.tenant)

    ScriptedModel.script!([
      {:tools,
       [
         {"compose_surface",
          %{"input" => %{"show" => "tasks", "display" => "board", "title" => "Your tasks"}}}
       ]},
      {:text, "SYNTHETIC: your tasks are on a board, by status."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    html = ask(view, ctx, "SYNTHETIC: show my tasks as a board")

    [_, id] = Regex.run(~r/data-surface-id="(s[0-9a-f]+)"/, html)
    assert has_element?(view, ~s(#surface-#{id}[phx-hook="InlineA2ui"]))
    assert has_element?(view, "#composed-#{id} h3", "Your tasks")

    # The container asks for its surface; the page composes it as the person
    # and pushes it to that container alone.
    render_hook(view, "assistant:surface", %{"id" => id})
    event = "a2ui:messages:" <> id
    assert_push_event(view, ^event, %{messages: [_ | _] = messages})
    assert Jason.encode!(messages) =~ "SYNTHETIC water the plants"

    # An id the page never showed gets nothing.
    render_hook(view, "assistant:surface", %{"id" => "sSYNTHETIC"})
    refute_push_event(view, "a2ui:messages:sSYNTHETIC", _)

    view |> element("#pin-#{id}") |> render_click()
    assert [app] = PinnedApp.mine!(actor: ctx.actor, tenant: ctx.tenant)
    assert app.title == "Tasks · board"
    assert app.display == :board

    # Pinning the same view again does not duplicate it.
    view |> element("#pin-#{id}") |> render_click()
    assert [_one] = PinnedApp.mine!(actor: ctx.actor, tenant: ctx.tenant)

    {:ok, launcher, _html} = live(conn, "/app")
    _ = render_async(launcher, 10_000)
    assert has_element?(launcher, "#launch-mine-#{app.id}", "Tasks · board")

    {:ok, mine, _html} = live(conn, "/app/mine/#{app.id}")
    _ = render_async(mine, 10_000)
    assert has_element?(mine, "#pinned-title", "Tasks · board")
    assert_push_event(mine, "a2ui:messages", %{messages: [_ | _]})

    assert {:error, {:live_redirect, %{to: "/app"}}} =
             mine |> element("#unpin") |> render_click()

    assert PinnedApp.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
  end

  # Minutes from now to `hour`:00 on `date`, on the display zone's clock.
  defp minutes_to(date, hour) do
    {midnight, _} = LocalTime.days(date, 1)
    midnight |> DateTime.add(hour, :hour) |> DateTime.diff(DateTime.utc_now(), :minute)
  end

  test "a question the Helper hands over is asked, and Monday's calendar shows Monday",
       %{conn: conn, ctx: ctx} do
    today = LocalTime.today()
    monday = Date.add(today, rem(8 - Date.day_of_week(today), 7))
    D.event!(ctx, "SYNTHETIC monday review", minutes_to(monday, 15), 30)
    D.event!(ctx, "SYNTHETIC tuesday after", minutes_to(Date.add(monday, 1), 15), 30)

    question = "show me all the calendar events I have for Monday"

    ScriptedModel.script!([
      {:tools,
       [
         {"compose_surface",
          %{"input" => %{"show" => "events", "display" => "calendar", "window" => "monday"}}}
       ]},
      {:text, "SYNTHETIC: Monday's events are on the calendar."}
    ])

    token = AssistantHandoff.token(ctx.user, question)
    {:ok, view, _html} = live(conn, "/app/agent?ask=" <> token)
    _ = render_async(view, 5_000)
    run_out!(ctx)
    html = await_answer(view)

    # Asked once, as the person's own question in their own thread.
    assert_received {:model_request, _messages, _tools, _opts}
    assert html =~ question

    [_, id] = Regex.run(~r/data-surface-id="(s[0-9a-f]+)"/, html)
    render_hook(view, "assistant:surface", %{"id" => id})
    event = "a2ui:messages:" <> id
    assert_push_event(view, ^event, %{messages: [_ | _] = messages})
    json = Jason.encode!(messages)
    assert json =~ "SYNTHETIC monday review"
    refute json =~ "SYNTHETIC tuesday after"
  end

  test "a hand-off token is its person's alone", %{conn: conn, ctx: ctx} do
    bob = F.colleague!(ctx, admin?: true)
    token = AssistantHandoff.token(bob.user, "SYNTHETIC: what is on my calendar?")

    {:ok, view, _html} = live(conn, "/app/agent?ask=" <> token)

    assert render(view) =~ "That question has expired"
    refute_received {:model_request, _, _, _}
    assert AssistantHandoff.question(ctx.user, "SYNTHETIC-not-a-token") == :error
  end

  test "somebody else's pinned app is not found", %{conn: conn, ctx: ctx} do
    bob = F.colleague!(ctx, admin?: true)

    {:ok, composed} = AshEnterprise.Assistant.Composer.compose(%{show: "tasks"})

    {:ok, app} =
      PinnedApp.pin(
        %{
          title: "Tasks",
          display: :table,
          source: "tasks",
          spec: AshA2ui.Dynamic.serialize(composed.surface)
        },
        actor: bob.actor,
        tenant: ctx.tenant
      )

    # The page navigates away once its read comes back empty.
    {:ok, view, _html} = live(conn, "/app/mine/#{app.id}")
    assert_redirect(view, "/app", 10_000)
  end

  test "a proposal waits for Confirm, then runs as the person", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([
      {:tools,
       [
         {"propose_task",
          %{
            "input" => %{
              "change" => "add",
              "title" => "SYNTHETIC book the room",
              "due" => "tomorrow"
            }
          }}
       ]},
      {:text, "SYNTHETIC: I proposed adding it. Confirm to add it."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    html = ask(view, ctx, "SYNTHETIC: remind me to book the room tomorrow")

    [_, id] = Regex.run(~r/id="confirm-(p[0-9a-f]+)"/, html)
    assert has_element?(view, "#proposal-#{id}", "SYNTHETIC book the room")
    assert has_element?(view, "#proposal-#{id}", "nothing has happened yet")
    assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []

    view |> element("#confirm-#{id}") |> render_click()

    assert [%Task{title: "SYNTHETIC book the room", source: "assistant"}] =
             Task.mine!(actor: ctx.actor, tenant: ctx.tenant)

    assert has_element?(view, "#proposal-#{id}", "Added to your action items")
    refute has_element?(view, "#confirm-#{id}")

    # Confirmed once: there is nothing left to confirm again.
    render_click(view, "confirm", %{"id" => id})
    assert [_one] = Task.mine!(actor: ctx.actor, tenant: ctx.tenant)
  end

  test "a pending decision survives a reload, runs through the engine once, and stays settled",
       %{conn: conn, ctx: ctx} do
    task =
      HumanTask.create!(%{node_id: "Review", name: "SYNTHETIC vendor contract sign-off"},
        tenant: ctx.tenant,
        authorize?: false
      )

    TaskCandidate.create!(
      %{task_id: task.id, principal_type: :user, principal_id: ctx.user.id},
      tenant: ctx.tenant,
      authorize?: false
    )

    ScriptedModel.script!([
      {:tools,
       [
         {"propose_decision",
          %{"input" => %{"on" => "task", "decision" => "approve", "target" => "vendor contract"}}}
       ]},
      {:text, "SYNTHETIC: I proposed approving it. Confirm to approve."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    html = ask(view, ctx, "SYNTHETIC: approve the vendor contract")
    [_, id] = Regex.run(~r/id="confirm-(p[0-9a-f]+)"/, html)
    assert has_element?(view, "#proposal-#{id}", "completes as approved")

    [thread] = History.threads(actor: ctx.actor, tenant: ctx.tenant)

    # A reload offers it again, rebuilt as the person.
    {:ok, reloaded, _html} = live(conn, "/app/agent/#{thread.id}")
    await_answer(reloaded, "#confirm-#{id}")

    reloaded |> element("#confirm-#{id}") |> render_click()
    assert has_element?(reloaded, "#proposal-#{id}", "Approved")

    assert Ash.get!(HumanTask, task.id, tenant: ctx.tenant, authorize?: false).status ==
             :completed

    # The first page still holds it as pending; its confirm is refused, not run twice.
    view |> element("#confirm-#{id}") |> render_click()
    assert has_element?(view, "#proposal-#{id}", "already confirmed")

    # And it stays settled.
    {:ok, again, _html} = live(conn, "/app/agent/#{thread.id}")
    await_answer(again, "#proposal-#{id}")
    refute has_element?(again, "#confirm-#{id}")
    assert has_element?(again, "#proposal-#{id}", "confirmed earlier")
  end

  test "a proposal recorded before settlements existed is shown, never offered again",
       %{conn: conn, ctx: ctx} do
    opts = [actor: ctx.actor, tenant: ctx.tenant]
    {:ok, thread} = Thread.start("SYNTHETIC older", opts)

    {:ok, _question} =
      Turn.append(%{thread_id: thread.id, role: :user, content: "SYNTHETIC"}, opts)

    wire = %{"kind" => "create_task", "title" => "SYNTHETIC older", "due_at" => nil}

    {:ok, _answer} =
      Turn.append(
        %{
          thread_id: thread.id,
          role: :assistant,
          content: "SYNTHETIC: proposed.",
          tool_calls: %{
            "calls" => [
              %{
                "name" => "propose_task",
                "arguments" => %{},
                "ok" => true,
                "proposal" => %{
                  "id" => "pold0001",
                  "wire" => wire,
                  "summary" => "SYNTHETIC older"
                }
              }
            ]
          }
        },
        opts
      )

    {:ok, view, _html} = live(conn, "/app/agent/#{thread.id}")
    await_answer(view, "#proposal-pold0001")
    refute has_element?(view, "#confirm-pold0001")
    assert has_element?(view, "#proposal-pold0001", "Proposed earlier")
  end

  test "a cancelled proposal stays cancelled after a reload", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([
      {:tools,
       [{"propose_task", %{"input" => %{"change" => "add", "title" => "SYNTHETIC water"}}}]},
      {:text, "SYNTHETIC: proposed."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    html = ask(view, ctx, "SYNTHETIC: remind me to water")
    [_, id] = Regex.run(~r/id="confirm-(p[0-9a-f]+)"/, html)
    view |> element("#cancel-#{id}") |> render_click()

    [thread] = History.threads(actor: ctx.actor, tenant: ctx.tenant)
    {:ok, reloaded, _html} = live(conn, "/app/agent/#{thread.id}")
    await_answer(reloaded, "#proposal-#{id}")
    refute has_element?(reloaded, "#confirm-#{id}")
    assert has_element?(reloaded, "#proposal-#{id}", "cancelled")
    assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
  end
end
