defmodule AshEnterpriseWeb.ShellLiveTest do
  @moduledoc """
  The command palette (ctrl+p) and surface launcher (ctrl+k) on every
  signed-in page (`AshEnterpriseWeb.Shell` over `AshA2ui.Shell.Component`).

  - The hook's events open each mode on any page.
  - The palette lists exactly the commands an ACP session as the same person
    is sent (`available_commands_update`), and the launcher every surface
    `_ash/surfaces/list` gives them plus the web's own pages.
  - `/open <surface> [id | n]`, a surface named directly, a command that
    names a surface, and a typed line for the agent all land where they
    should.
  - A member without a surface's door is not offered it, and a forged open
    is refused again on the way in.
  - `/app` is the launcher's full-page form: the same surfaces, the same
    filter.

  SYNTHETIC data only.
  """

  # async: false -- the ACP comparison sets the deployment's operator email.
  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshAcp.Server
  alias AshEnterprise.Acp.ExtMethods
  alias AshEnterprise.Surfaces
  alias AshEnterpriseWeb.{AssistantHandoff, Shell}

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  setup %{conn: conn} do
    original = Application.get_all_env(:ash_acp)
    on_exit(fn -> Enum.each(original, fn {k, v} -> Application.put_env(:ash_acp, k, v) end) end)
    on_exit(fn -> Application.delete_env(:ash_enterprise, :acp_operator_email) end)

    ctx = tenant!(operator?: true)
    %{conn: sign_in(conn, ctx.user), ctx: ctx}
  end

  defp shell(view), do: element(view, "#a2ui-shell")

  defp open(view, mode) do
    render_hook(shell(view), "shell:open", %{"mode" => mode})
    view
  end

  defp submit(view, line),
    do: view |> element("#a2ui-shell-form") |> render_submit(%{"query" => line})

  # The rows the open shell lists, by their label.
  defp labels(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#a2ui-shell-list [role=option] > span:first-child")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp landed({:error, {kind, %{to: to}}}) when kind in [:redirect, :live_redirect], do: to

  test "ctrl+p and ctrl+k open the palette and the launcher, on any page", %{conn: conn} do
    for path <- [~p"/app", ~p"/app/calendar", ~p"/app/lineage"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, ~s(#a2ui-shell[phx-hook="AshA2uiShell"][data-open="false"]))
      refute has_element?(view, "#a2ui-shell-dialog")

      open(view, "palette")
      assert has_element?(view, ~s(#a2ui-shell[data-open="true"][data-mode="palette"]))
      assert has_element?(view, "#a2ui-shell-item-0", "Open a surface…")

      open(view, "launcher")
      assert has_element?(view, ~s(#a2ui-shell[data-mode="launcher"]))
      render_hook(shell(view), "shell:close", %{})
      refute has_element?(view, "#a2ui-shell-dialog")
    end
  end

  test "the hook reads its keys from the shell's table, and the header opens it too",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/today")
    html = render(shell(view))
    assert html =~ "&quot;ctrl+p&quot;:&quot;palette&quot;"
    assert html =~ "&quot;ctrl+k&quot;:&quot;launcher&quot;"
    assert render(element(view, "#nav-palette")) =~ "ash_a2ui:shell"
  end

  test "the palette lists the same commands an ACP session gets", %{conn: conn, ctx: ctx} do
    acp = acp_session(ctx)
    assert acp.commands != []

    # The host's list is ACP's, map for map.
    assert Shell.commands(ctx.actor) == acp.commands

    {:ok, view, _html} = live(conn, ~p"/app")
    commands = view |> open("palette") |> labels() |> Enum.filter(&String.starts_with?(&1, "/"))

    assert commands == Enum.map(acp.commands, &("/" <> &1["name"]))
  end

  test "the launcher lists ACP's surfaces and the web's own pages", %{conn: conn, ctx: ctx} do
    acp = acp_session(ctx)
    web = ExtMethods.entries(ctx.actor, :web)

    assert acp.surfaces -- web == []
    assert Enum.map(web, & &1["id"]) == Enum.map(Surfaces.openable(ctx.actor), &to_string(&1.key))

    {:ok, view, _html} = live(conn, ~p"/app/today")
    listed = view |> open("launcher") |> labels()
    assert listed == Enum.map(web, & &1["title"])

    # The recent additions are all in it.
    for title <- ["Calendar", "Agent", "Action items", "Lineage", "Audit trail", "Time travel"] do
      assert title in listed, "#{title} is missing from the launcher"
    end

    assert Enum.any?(listed, &(&1 =~ "flight" or &1 =~ "Flight"))
  end

  test "/open calendar navigates to the calendar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "palette")
    assert landed(submit(view, "/open calendar")) == "/app/calendar"
  end

  test "the launcher filters and enter opens the match", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "launcher")
    view |> element("#a2ui-shell-form") |> render_change(%{"query" => "time trav"})
    assert labels(view) == ["Time travel"]
    assert landed(submit(view, "time trav")) == "/app/time-travel"
  end

  test "a surface named directly, and a command that names a surface, open it",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app/calendar")
    open(view, "palette")
    assert landed(submit(view, "/agent")) == "/app/agent"

    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "palette")
    assert landed(submit(view, "/approvals")) == "/app/approvals"
  end

  test "/open <surface> <id> and <n> go through the deep link", %{conn: conn, ctx: ctx} do
    person = person!(ctx, "maya@example.test", "Maya Example")

    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "palette")
    assert landed(submit(view, "/open people #{person.id}")) == "/app/r/people/#{person.id}"

    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "palette")
    assert landed(submit(view, "/open people 1")) == "/app/r/people/row/1"

    # The row link lands on the surface with that row's record selected.
    conn = get(conn, ~p"/app/r/people/row/1")
    assert redirected_to(conn) =~ "/app/people?"
    assert redirected_to(conn) =~ person.id
  end

  test "a row past the list says so", %{conn: conn} do
    conn = get(conn, ~p"/app/r/people/row/99")
    assert redirected_to(conn) == "/app"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "People has no row 99"
  end

  test "a typed line goes to the agent as a prompt, as the person", %{conn: conn, ctx: ctx} do
    {:ok, view, _html} = live(conn, ~p"/app/today")
    open(view, "palette")
    view |> element("#a2ui-shell-form") |> render_change(%{"query" => "what is on today"})
    assert List.last(labels(view)) == "Ask the agent"

    to = landed(submit(view, "what is on today"))
    %URI{path: "/app/agent", query: query} = URI.parse(to)
    %{"ask" => token} = URI.decode_query(query)
    assert AssistantHandoff.question(ctx.user, token) == {:ok, "what is on today"}
  end

  test "a command with words, or a verb, goes to the agent", %{conn: conn, ctx: ctx} do
    {:ok, view, _html} = live(conn, ~p"/app")
    open(view, "palette")
    %URI{query: query} = view |> submit("/calendar week") |> landed() |> URI.parse()
    %{"ask" => token} = URI.decode_query(query)
    assert AssistantHandoff.question(ctx.user, token) == {:ok, "calendar week"}
  end

  describe "a member without the door" do
    setup %{ctx: ctx} do
      nobody = quietly(fn -> member!(ctx, "No access", []) end)
      %{nobody: nobody, conn: sign_in(build_conn(), nobody.user)}
    end

    test "is not offered the surface or its command", %{conn: conn, nobody: nobody} do
      {:ok, view, _html} = live(conn, ~p"/app")

      listed = view |> open("launcher") |> labels()
      assert "Calendar" in listed
      refute "Lineage" in listed
      refute "Audit trail" in listed
      refute "Erasure scopes" in listed

      palette = view |> open("palette") |> labels()
      refute "/lineage" in palette
      refute "/erasure" in palette

      for surface <- Surfaces.all(), not Surfaces.open?(surface, nobody.actor) do
        refute surface.label in listed, "#{surface.key} is offered behind a closed door"
      end

      # Typing it is no way round: the shell only routes what it lists.
      view |> element("#a2ui-shell-form") |> render_change(%{"query" => "/open lineage"})
      assert has_element?(view, "#a2ui-shell-item-0", "There is no lineage surface")
    end

    test "and a forged open is refused on the way in", %{nobody: nobody} do
      socket = %Phoenix.LiveView.Socket{}

      assert {:error, message} =
               Shell.invoke({:open_surface, %{"id" => "lineage"}, nil}, nobody.actor, socket)

      assert message =~ "Lineage is for"
    end

    test "/app lists the same surfaces as the launcher", %{conn: conn, nobody: nobody} do
      {:ok, view, _html} = live(conn, ~p"/app")

      for %{"id" => id} <- Shell.surfaces(nobody.actor), id != "today" do
        assert has_element?(view, "#launch-#{id}")
      end

      refute has_element?(view, "#launch-lineage")
    end
  end

  test "/app's filter narrows the cards as the launcher does, and enter opens the first",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/app")
    assert has_element?(view, "#launch-calendar")

    view |> element("#launch-filter") |> render_change(%{"launch" => %{"q" => "time travel"}})
    assert has_element?(view, "#launch-time_travel")
    refute has_element?(view, "#launch-calendar")
    refute has_element?(view, "#launch-today")

    view |> element("#launch-filter") |> render_change(%{"launch" => %{"q" => "zzz"}})
    assert has_element?(view, "#launch-no-match")

    assert {:error, {:live_redirect, %{to: "/app/time-travel"}}} =
             view
             |> element("#launch-filter")
             |> render_submit(%{"launch" => %{"q" => "time travel"}})
  end

  # -- ACP, as the same person ----------------------------------------------------

  defp acp_session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)

    {_init, _, state} =
      rpc(Server.new(AshAcp.config()), "initialize", %{"protocolVersion" => 1})

    {resp, updates, state} = rpc(state, "session/new", %{"cwd" => "/tmp"})
    sid = resp["result"]["sessionId"]
    {list, _updates, _state} = rpc(state, "_ash/surfaces/list", %{"sessionId" => sid})

    commands =
      Enum.find_value(updates, fn
        %{"params" => %{"update" => %{"sessionUpdate" => "available_commands_update"} = u}} ->
          u["availableCommands"]

        _other ->
          nil
      end)

    %{commands: commands, surfaces: list["result"]["surfaces"]}
  end

  defp rpc(state, method, params) do
    Server.handle_message(
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      state
    )
  end

  defp quietly(fun) do
    ExUnit.CaptureLog.with_log(fun) |> elem(0)
  end
end
