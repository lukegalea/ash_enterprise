defmodule AshEnterpriseWeb.AssistantComposeLiveTest do
  @moduledoc """
  `/app/agent` composing and proposing (E10.3, E10.4) through the real
  LiveView: a composed board renders inline as the person and pins into "My
  apps" on the launcher, where it opens (re-verified) and unpins; a proposal
  waits for Confirm and then runs as the person. A scripted model stands in
  for the in-zone runtime; every row is synthetic.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshEnterprise.Assistant.PinnedApp
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel

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

  defp ask(view, question) do
    view |> form("#ask-form", ask: %{question: question}) |> render_submit()
    await_answer(view)
  end

  setup %{conn: conn} do
    F.in_zone!()
    ctx = F.tenant!()
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
    html = ask(view, "SYNTHETIC: show my tasks as a board")

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
    html = ask(view, "SYNTHETIC: remind me to book the room tomorrow")

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
end
