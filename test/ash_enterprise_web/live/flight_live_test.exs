defmodule AshEnterpriseWeb.FlightLiveTest do
  @moduledoc """
  The process flight views through the real LiveViews (PROD-10).

    * A morning brief waiting for approval draws the `morning.brief` process
      with its marker on "Approve the brief", for its owner — a member with no
      process grants, who reads the run because its approval task waits on
      them.
    * Approving the task moves the marker while the page is open: the engine's
      broadcast prompts a refresh, which reads the run again as the owner and
      finds it ended at "EndApproved".
    * Someone who can read neither the run nor its task is refused: the deep
      link says "not found, or not yours", and the page draws nothing of it.

  SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Bpmn.{HumanTask, Instance}
  alias AshEnterprise.Process.Resolver

  setup %{conn: conn} do
    platform_brief_process!()
    on_exit(&Resolver.forget_platform_tenant/0)

    admin = tenant!()
    owner = member!(admin, "No process grants", [])
    stranger = member!(admin, "No process grants either", [])

    {:ok, _said} = MorningBrief.compose_today(actor: owner.actor, tenant: owner.tenant)
    instance = instance_of!(owner)

    %{conn: conn, admin: admin, owner: owner, stranger: stranger, instance: instance}
  end

  test "a brief awaiting approval draws its process with the marker on the approval step", ctx do
    {:ok, view, _html} = open_run(ctx.conn, ctx.owner.user, ctx.instance.id)

    assert has_element?(view, "#ash-a2ui-surface[phx-hook=AshA2ui]")

    surface = pushed(view)

    # The diagram is the process's own drawing, with node ids the markers sit on.
    assert surface =~ "liveDiagram"
    assert surface =~ "flowchart TD"
    assert surface =~ "ApproveBrief"

    assert [marker] = markers(surface, "ApproveBrief")
    assert marker["status"] == "waiting"
    assert marker["label"] =~ "Morning brief"
    # The marker opens the task it waits on.
    assert marker["link"]["surface"] == "approvals"
    assert other_markers(surface, "ApproveBrief") == []
  end

  test "approving the brief moves the marker to where the run ended, live", ctx do
    {:ok, view, _html} = open_run(ctx.conn, ctx.owner.user, ctx.instance.id)

    assert [%{"status" => "waiting"}] = markers(pushed(view), "ApproveBrief")

    task = task_of!(ctx.instance, ctx.owner)

    {:ok, _said} =
      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
        # Built now, as a request would: the fixture's context predates the task.
        actor: actor(ctx.owner.user),
        tenant: ctx.owner.tenant
      )
      |> Ash.run_action()

    # The engine's broadcast reaches the page; its refresh reads the run again.
    refreshed = pushed(view)
    assert markers(refreshed, "ApproveBrief") == []
    assert [%{"status" => "done"}] = markers(refreshed, "EndApproved")
  end

  test "someone who can read neither the run nor its task is refused", ctx do
    conn = sign_in(ctx.conn, ctx.stranger.user)

    # The deep link re-authorizes the run as them: one answer, at the launcher.
    conn = get(conn, "/app/r/flight/#{ctx.instance.id}")
    assert redirected_to(conn) == "/app"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found, or it is not yours"

    # Naming the run in the URL draws nothing of it.
    {:ok, view, _html} =
      live(sign_in(ctx.conn, ctx.stranger.user), "/app/flights?ctx[instance]=#{ctx.instance.id}")

    surface = pushed(view)
    refute surface =~ "ApproveBrief"
    refute surface =~ "Morning brief"
    assert surface =~ "This diagram is unavailable."
  end

  test "the brief process view shows each owner only their own runs", ctx do
    {:ok, _said} =
      MorningBrief.compose_today(actor: ctx.stranger.actor, tenant: ctx.stranger.tenant)

    {:ok, view, _html} = live(sign_in(ctx.conn, ctx.owner.user), "/app/flights/briefs")
    surface = pushed(view)
    assert [mine] = markers(surface, "ApproveBrief")
    assert mine["link"]["recordId"] == ctx.instance.id

    # The tenant's administrator reads every run (a role grant).
    {:ok, view, _html} = live(sign_in(ctx.conn, ctx.admin.user), "/app/flights/briefs")
    assert length(markers(pushed(view), "ApproveBrief")) == 2
  end

  test "Today's brief and the task on Approvals link to the run's flight view", ctx do
    task = task_of!(ctx.instance, ctx.owner)
    link = ~s("href":"/app/r/flight/#{ctx.instance.id}")

    {:ok, view, _html} =
      live(sign_in(ctx.conn, ctx.owner.user), "/app/approvals?ctx[task]=#{task.id}")

    assert all_pushed(view) =~ link

    brief = brief_of!(ctx.instance, ctx.owner)

    {:ok, view, _html} =
      live(sign_in(ctx.conn, ctx.owner.user), "/app/today?ctx[brief]=#{brief.id}")

    assert all_pushed(view) =~ link
  end

  test "the flight views are in the launcher, and each one mounts its surface", ctx do
    conn = sign_in(ctx.conn, ctx.owner.user)
    {:ok, _view, html} = live(conn, "/app")

    for path <- ~w(/app/flights /app/flights/briefs /app/flights/stewardship) do
      assert html =~ ~s(href="#{path}"), path

      {:ok, view, _html} = live(sign_in(ctx.conn, ctx.owner.user), path)
      assert has_element?(view, "#ash-a2ui-surface[phx-hook=AshA2ui]"), path
      assert pushed(view) =~ "liveDiagram", path
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> recycle()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # The deep link a "Where it stands" link carries: it re-authorizes the run
  # and redirects to the flight view with the run selected.
  defp open_run(conn, user, id) do
    redirected = get(sign_in(conn, user), "/app/r/flight/#{id}")
    path = redirected_to(redirected)
    assert path =~ "/app/flights?"
    live(sign_in(conn, user), path)
  end

  defp pushed(view) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 5_000)
    JSON.encode!(messages)
  end

  defp all_pushed(view, acc \\ []) do
    assert_push_event(view, "a2ui:messages", %{messages: messages}, 500)
    all_pushed(view, [JSON.encode!(messages) | acc])
  rescue
    ExUnit.AssertionError -> acc |> Enum.reverse() |> Enum.join("\n")
  end

  # The markers on `node` in a pushed payload's `/diagram/flight` state.
  defp markers(encoded, node), do: Map.get(diagram_markers(encoded), node, [])

  defp other_markers(encoded, node),
    do: encoded |> diagram_markers() |> Map.delete(node) |> Map.values() |> List.flatten()

  defp diagram_markers(encoded) do
    encoded
    |> JSON.decode!()
    |> find_diagram()
    |> case do
      %{"markers" => markers} -> markers
      _none -> %{}
    end
  end

  defp find_diagram(%{"diagram" => %{"flight" => state}}), do: state
  defp find_diagram(%{"path" => "/diagram/flight", "value" => state}), do: state

  defp find_diagram(map) when is_map(map),
    do: Enum.find_value(Map.values(map), &find_diagram/1)

  defp find_diagram(list) when is_list(list), do: Enum.find_value(list, &find_diagram/1)
  defp find_diagram(_other), do: nil

  defp instance_of!(%{tenant: tenant, user: user}) do
    Instance
    |> Ash.Query.filter(started_by_id == ^user.id)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp brief_of!(instance, %{tenant: tenant}) do
    MorningBrief
    |> Ash.Query.filter(id == ^instance.subject_id)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp task_of!(instance, %{tenant: tenant}) do
    HumanTask
    |> Ash.Query.filter(instance_id == ^instance.id and status in [:open, :claimed])
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end
end
