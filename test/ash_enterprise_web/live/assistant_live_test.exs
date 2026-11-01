defmodule AshEnterpriseWeb.AssistantLiveTest do
  @moduledoc """
  `/app/agent` through the real LiveView (E10.1): a question starts a run of
  the assistant agent, which the test steps as its jobs would; the page follows
  it, shows its lookups inline and links its citations; the thread is kept and
  reopens, with a run still going picked up again; somebody else's thread is
  "not found"; a failed answer says why and retries; Stop stops; and with no
  in-zone model the page says so and asks nothing. A scripted model stands in
  for the in-zone runtime; every row is synthetic.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Assistant.Thread
  alias AshEnterprise.Execution
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.DailyFixtures, as: D

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # The page's runs, run out here as their jobs would run them; each step reaches
  # the page over PubSub.
  defp run_out!(ctx) do
    for run <- Execution.list_agent_runs!(authorize?: false, tenant: ctx.tenant),
        do: F.run_out!(run)
  end

  # The page settles the answer when it hears the run end; wait for the live
  # turn to go and the recorded answer to appear.
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

  setup %{conn: conn} do
    F.in_zone!()
    ctx = F.tenant!()
    F.published!(ctx)
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  test "is in the registry, opens behind the door, and offers suggestions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/app/agent")

    assert has_element?(view, "#page-header h1", "Agent")
    assert has_element?(view, "#model-status", "In-zone model")
    assert has_element?(view, "#assistant-empty")
    assert has_element?(view, "#suggestion-0")
    assert has_element?(view, "#ask-form")

    {:ok, _launcher, html} = live(conn, "/app")
    assert html =~ "/app/agent"
  end

  test "asks, shows the lookup inline, cites the record, and keeps the thread",
       %{conn: conn, ctx: ctx} do
    event =
      D.event!(ctx, "SYNTHETIC design review", 90, 30, starts_at: D.today_at(~T[12:00:00]))

    ScriptedModel.script!([
      {:tools, [{"calendar_events", %{"input" => %{"window" => "today"}}}]},
      {:text, "You have the SYNTHETIC design review today [[calendar:#{event.id}]]."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")

    view
    |> form("#ask-form", ask: %{question: "SYNTHETIC: what is on today?"})
    |> render_submit()

    assert has_element?(view, "#live-turn")
    run_out!(ctx)
    html = await_answer(view)

    assert html =~ "SYNTHETIC: what is on today?"
    assert html =~ "You have the SYNTHETIC design review today"
    assert has_element?(view, "#turns details summary", "Calendar events")
    assert has_element?(view, "#turns details summary", "1 row")
    assert has_element?(view, ~s(#turns a[href="/app/r/calendar/#{event.id}"]))
    refute html =~ "[[calendar:"

    [thread] = Thread.mine!(actor: ctx.actor, tenant: ctx.tenant)
    assert_patch(view, "/app/agent/#{thread.id}")

    # Reopened from its URL, the conversation is still there.
    {:ok, reopened, html} = live(conn, "/app/agent/#{thread.id}")
    _ = render_async(reopened, 5_000)
    assert render(reopened) =~ "You have the SYNTHETIC design review today"
    assert html =~ "thread-#{thread.id}" or has_element?(reopened, "#thread-#{thread.id}")
  end

  test "a reopened thread picks up the run still answering it", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([{:text, "SYNTHETIC: answered after the page was gone."}])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: later?"}) |> render_submit()
    [thread] = Thread.mine!(actor: ctx.actor, tenant: ctx.tenant)
    GenServer.stop(view.pid)

    {:ok, reopened, _html} = live(conn, "/app/agent/#{thread.id}")
    _ = render_async(reopened, 5_000)
    assert has_element?(reopened, "#live-turn")

    run_out!(ctx)
    assert await_answer(reopened) =~ "SYNTHETIC: answered after the page was gone."
  end

  test "an uncited or invented ref is not linked", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([
      {:text, "SYNTHETIC answer [[calendar:#{Ash.UUID.generate()}]]."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC?"}) |> render_submit()
    run_out!(ctx)
    html = await_answer(view)

    assert html =~ "SYNTHETIC answer"
    refute has_element?(view, ~s(#turns a[href^="/app/r/"]))
  end

  test "somebody else's thread is not found", %{conn: conn, ctx: ctx} do
    bob = F.colleague!(ctx, admin?: true)
    {:ok, theirs} = Thread.start("SYNTHETIC-BOBS-THREAD", actor: bob.actor, tenant: bob.tenant)

    {:ok, view, _html} = live(conn, "/app/agent/#{theirs.id}")
    _ = render_async(view, 5_000)

    assert_patch(view, "/app/agent")
    assert has_element?(view, "#assistant-notice", "not found")
    refute render(view) =~ "SYNTHETIC-BOBS-THREAD"
  end

  test "a failed answer says why, and Retry answers it", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([
      {:text, ""},
      {:text, ""},
      {:text, "SYNTHETIC: answered on the second try."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: hello?"}) |> render_submit()
    run_out!(ctx)

    html = await_answer(view, "#turns button[phx-click=retry]")
    assert html =~ "empty answer"

    view |> element("#turns button[phx-click=retry]") |> render_click()
    run_out!(ctx)
    await_answer(view)

    assert eventually(fn -> render(view) =~ "answered on the second try" end)
  end

  test "Stop stops the run and keeps what it had", %{conn: conn, ctx: ctx} do
    ScriptedModel.script!([{:tools, [{"pending_approvals", %{"input" => %{}}}]}])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: go on…"}) |> render_submit()

    # One step: the lookup is in the run's journal, and the run goes on.
    [run] = Execution.list_agent_runs!(authorize?: false, tenant: ctx.tenant)
    AshEnterprise.Test.Execution.Runs.step!(run)
    assert eventually(fn -> render(view) =~ "Pending approvals" end)

    view |> element("#ask-stop") |> render_click()

    assert eventually(fn -> not has_element?(view, "#live-turn") end)
    assert render(view) =~ "Stopped."
    assert has_element?(view, "#turns details summary", "Pending approvals")
    assert AshEnterprise.Test.Execution.Runs.run(run).status == :cancelled
  end

  test "a member not given the assistant is told so, and nothing is asked",
       %{conn: conn, ctx: ctx} do
    carol = F.colleague!(ctx)
    ScriptedModel.script!([{:text, "SYNTHETIC: must never be produced"}])

    {:ok, view, _html} = live(sign_in(conn, carol.user), "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: may I?"}) |> render_submit()

    assert eventually(fn -> render(view) =~ "start grant" end)
    refute_received {:model_request, _, _, _}
  end

  test "with no in-zone model the page says so and asks nothing", %{conn: conn} do
    Application.put_env(:ash_enterprise, :ai, [])

    {:ok, view, _html} = live(conn, "/app/agent")

    assert has_element?(view, "#model-status", "not configured")
    assert has_element?(view, "#ask-send[disabled]")
  end

  defp eventually(fun) do
    Enum.reduce_while(1..100, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        receive do
        after
          50 -> {:cont, false}
        end
      end
    end)
  end
end
