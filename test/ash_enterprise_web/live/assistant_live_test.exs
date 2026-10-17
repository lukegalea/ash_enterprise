defmodule AshEnterpriseWeb.AssistantLiveTest do
  @moduledoc """
  `/app/agent` through the real LiveView (E10.1): a question streams an
  answer with its lookups shown inline and its citations linked; the thread
  is kept and reopens; somebody else's thread is "not found"; a failed
  answer says why and retries; Stop stops; and with no in-zone model the
  page says so and asks nothing. A scripted model stands in for the in-zone
  runtime; every row is synthetic.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Assistant.Thread
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterprise.Test.DailyFixtures, as: D

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # The answer lands from a run in another process; wait for the live turn
  # to go and the recorded answer to appear.
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
    event = D.event!(ctx, "SYNTHETIC design review", 90, 30)

    ScriptedModel.script!([
      {:tools, [{"calendar_events", %{"input" => %{"window" => "today"}}}]},
      {:text, "You have the SYNTHETIC design review today [[calendar:#{event.id}]]."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")

    view
    |> form("#ask-form", ask: %{question: "SYNTHETIC: what is on today?"})
    |> render_submit()

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

  test "an uncited or invented ref is not linked", %{conn: conn} do
    ScriptedModel.script!([
      {:text, "SYNTHETIC answer [[calendar:#{Ash.UUID.generate()}]]."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC?"}) |> render_submit()
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

  test "a failed answer says why, and Retry answers it", %{conn: conn} do
    ScriptedModel.script!([
      {:error, %ReqLLM.Error.API.Request{reason: "SYNTHETIC unreachable"}},
      {:text, "SYNTHETIC: answered on the second try."}
    ])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: hello?"}) |> render_submit()

    html = await_answer(view, "#turns button[phx-click=retry]")
    assert html =~ "did not answer"
    assert html =~ "Nothing was sent anywhere else"

    view |> element("#turns button[phx-click=retry]") |> render_click()

    await_answer(view)

    assert eventually(fn -> render(view) =~ "answered on the second try" end)
  end

  test "Stop stops the run and keeps what it had", %{conn: conn} do
    ScriptedModel.script!([{:pause, "SYNTHETIC-PARTIAL"}])

    {:ok, view, _html} = live(conn, "/app/agent")
    view |> form("#ask-form", ask: %{question: "SYNTHETIC: go on…"}) |> render_submit()

    assert eventually(fn -> render(view) =~ "SYNTHETIC-PARTIAL" end)
    assert has_element?(view, "#ask-stop")

    view |> element("#ask-stop") |> render_click()
    # The scripted model is waiting for its next chunk; let it send one so
    # the run notices the stop at that chunk.
    for pid <- Task.Supervisor.children(AshEnterprise.TaskSupervisor),
        do: send(pid, :scripted_continue)

    assert eventually(fn -> not has_element?(view, "#live-turn") end)
    assert render(view) =~ "Stopped."
    assert render(view) =~ "SYNTHETIC-PARTIAL"
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
