defmodule AshEnterprise.DailyBriefLoopTest do
  @moduledoc """
  The morning brief's whole loop, against the platform baseline only (no
  tenant copy of `morning.brief`, as on the dogfood instance):

    * the scheduler, at the compose hour, enqueues one compose per calendar
      owner; draining it creates the owner's brief and starts the process as
      them, which composes the draft and opens the approval task on them;
    * a second tick is a no-op (one job, one brief per owner per day);
    * Approve on Today (web) completes the task and the brief is approved;
    * on demand: Today's Compose button, and `brief` over ACP (a permission
      request first), do the same for the actor; `reject brief` in the
      permission modal rejects it;
    * before the compose hour the scheduler does nothing, and a job for a
      day that is no longer today cancels.

  Oban runs `testing: :manual`; the scheduler's jobs are drained here, and the
  process engine's advances run inline (`config :ash_bpmn, oban_testing: :inline`).
  """

  use AshEnterpriseWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshAcp.Server
  alias AshEnterprise.Acp
  alias AshEnterprise.Agents.{MorningBrief, MorningBriefScheduler, MorningBriefWorker}
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance}
  alias AshEnterprise.Platform.{LocalTime, Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver

  setup do
    Resolver.forget_platform_tenant()
    platform = Seeder.seed_platform_organization()
    opts = [actor: SystemActor.process(), tenant: platform.id]

    baseline =
      %{
        key: "morning.brief",
        name: "Morning brief",
        xml: File.read!("priv/bpmn/morning_brief.bpmn")
      }
      |> Definition.create!(opts)
      |> Definition.publish!(opts)

    compose_at = Application.get_env(:ash_enterprise, :morning_brief_compose_at)
    Application.put_env(:ash_enterprise, :morning_brief_compose_at, ~T[00:00:00])
    acp = Application.get_all_env(:ash_acp)

    on_exit(fn ->
      Resolver.forget_platform_tenant()
      Application.put_env(:ash_enterprise, :morning_brief_compose_at, compose_at)
      Enum.each(acp, fn {k, v} -> Application.put_env(:ash_acp, k, v) end)
      Application.delete_env(:ash_enterprise, :acp_operator_email)
    end)

    %{baseline: baseline}
  end

  test "scheduled at the compose hour, composed by the process, approved on Today", %{
    conn: conn,
    baseline: baseline
  } do
    ctx = tenant!()
    linked_account!(ctx, "google-calendar")
    event!(ctx, "Synthetic standup", minutes_until_noon(), 30)

    # Someone with no calendar linked is not in the population.
    bystander = tenant!()

    assert %{success: 2} = tick!()

    [brief] = briefs(ctx)
    assert brief.brief_date == LocalTime.today()
    assert brief.status == :pending_approval
    assert brief.draft_text =~ "Synthetic standup"

    # Started from the platform baseline, as the owner.
    instance = instance_for!(brief, ctx)
    assert instance.definition_id == baseline.id
    assert instance.started_by_id == ctx.user.id
    assert instance.organization_id == ctx.tenant

    # The approval task waits on the owner.
    assert [task] = awaiting(ctx)
    assert task.instance_id == instance.id

    assert briefs(bystander) == []

    # A later tick the same day changes nothing: the owner's job for the day
    # already exists, so nothing is enqueued.
    assert %{owners: 1, enqueued: 0, already_enqueued: 1} =
             MorningBriefScheduler.enqueue(LocalTime.now())

    assert %{success: 0} = Oban.drain_queue(queue: :default)
    assert [%{id: same}] = briefs(ctx)
    assert same == brief.id

    # Approve on Today, through the approval task.
    {:ok, view, _html} = live(sign_in(conn, ctx.user), "/app/today")
    assert_push_event(view, "a2ui:messages", %{messages: _bootstrap}, 5_000)

    render_hook(view, "a2ui:action", %{
      "version" => "v1.0",
      "action" => %{
        "name" => "invoke",
        "surfaceId" => "today",
        "sourceComponentId" => "data_grid_brief",
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "context" => %{"action" => "approve", "recordId" => brief.id, "component" => "brief"}
      }
    })

    assert %{status: :approved} = reload_brief!(brief, ctx.tenant)
    assert %{status: :completed} = instance_for!(brief, ctx)
    assert awaiting(ctx) == []
  end

  test "Today offers Compose until the day has a brief", %{conn: conn} do
    ctx = tenant!()
    event!(ctx, "Synthetic review", minutes_until_noon(), 45)

    {:ok, view, _html} = live(sign_in(conn, ctx.user), "/app/today")
    render_async(view)
    assert has_element?(view, "#compose-brief")

    view |> element("#compose-brief") |> render_click()
    render_async(view, 5_000)

    assert [brief] = briefs(ctx)
    assert brief.status == :pending_approval
    assert brief.draft_text =~ "Synthetic review"
    assert [_task] = awaiting(ctx)
    refute has_element?(view, "#compose-brief")

    # A fresh visit the same day does not offer it again.
    {:ok, view, _html} = live(sign_in(build_conn(), ctx.user), "/app/today")
    render_async(view)
    refute has_element?(view, "#compose-brief")
  end

  test "over ACP: `brief` composes after a permission request; `reject brief` rejects it" do
    ctx = tenant!()
    s = session(ctx)

    turn = prompt(s, "brief")
    assert %{"params" => %{"toolCall" => %{"title" => "Compose today's brief"}}} = turn.permission
    assert briefs(ctx) == [], "nothing is composed until the request is allowed"

    allowed = allow!(turn)
    assert allowed.response["result"]["stopReason"] == "end_turn"
    assert allowed.said =~ "Composing your morning brief"

    assert [brief] = briefs(ctx)
    assert brief.draft_text =~ "No events scheduled"

    # Once the day has a brief, `compose brief` shows it rather than asking.
    again = prompt(allowed.state, "compose brief")
    assert again.permission == nil
    assert again.said =~ "waiting for your approval"
    assert [_one] = briefs(ctx)

    reject = prompt(again.state, "reject brief")

    assert %{"params" => %{"toolCall" => %{"title" => "Reject: Morning brief" <> _}}} =
             reject.permission

    assert allow!(reject).response["result"]["stopReason"] == "end_turn"
    assert %{status: :rejected} = reload_brief!(brief, ctx.tenant)
    assert %{status: :completed} = instance_for!(brief, ctx)
  end

  test "before the compose hour the scheduler waits; a stale day's job cancels" do
    ctx = tenant!()
    linked_account!(ctx, "google-calendar")
    Application.put_env(:ash_enterprise, :morning_brief_compose_at, ~T[06:30:00])

    early = DateTime.new!(LocalTime.today(), ~T[06:29:00], LocalTime.zone(), Tz.TimeZoneDatabase)
    assert %{waiting_until: ~T[06:30:00]} = MorningBriefScheduler.enqueue(early)
    assert %{success: 0} = Oban.drain_queue(queue: :default)
    assert briefs(ctx) == []

    yesterday = Date.add(LocalTime.today(), -1)

    assert {:cancel, :not_today} =
             MorningBriefWorker.perform(%Oban.Job{
               args: %{
                 "user_id" => ctx.user.id,
                 "organization_id" => ctx.tenant,
                 "brief_date" => Date.to_iso8601(yesterday)
               }
             })

    assert briefs(ctx) == []
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tick! do
    Oban.insert!(MorningBriefScheduler.new(%{}))
    Oban.drain_queue(queue: :default, with_recursion: true)
  end

  # An event at noon today, local (the test zone is UTC), wherever "now" is.
  defp minutes_until_noon do
    noon = DateTime.new!(LocalTime.today(), ~T[12:00:00], LocalTime.zone(), Tz.TimeZoneDatabase)
    DateTime.diff(noon, DateTime.utc_now(), :minute)
  end

  defp briefs(%{user: user, tenant: tenant}) do
    MorningBrief
    |> Ash.Query.filter(owner_id == ^user.id)
    |> Ash.Query.load(:draft_text)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp instance_for!(brief, %{tenant: tenant}) do
    subject_type = to_string(MorningBrief)

    Instance
    |> Ash.Query.filter(subject_type == ^subject_type and subject_id == ^brief.id)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp awaiting(%{actor: actor, tenant: tenant}) do
    HumanTask
    |> Ash.Query.for_read(:awaiting_me, %{}, actor: actor, tenant: tenant)
    |> Ash.read!(actor: actor, tenant: tenant)
  end

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  # An ACP session for `ctx`'s user, as `scripts/acp-attach` opens one.
  defp session(ctx) do
    Application.put_env(:ash_enterprise, :acp_operator_email, ctx.email)
    message = &%{"jsonrpc" => "2.0", "id" => &1, "method" => &2, "params" => &3}

    {_, _, state} =
      Server.handle_message(
        message.(1, "initialize", %{"protocolVersion" => 1}),
        Server.new(Acp.server_config())
      )

    {resp, _, state} =
      Server.handle_message(message.(2, "session/new", %{"cwd" => "/tmp"}), state)

    {resp["result"]["sessionId"], state}
  end

  defp prompt({sid, state}, text) do
    {resp, updates, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => System.unique_integer([:positive]),
          "method" => "session/prompt",
          "params" => %{"sessionId" => sid, "prompt" => [%{"type" => "text", "text" => text}]}
        },
        state
      )

    turn(resp, updates, {sid, state})
  end

  # Answers the turn's permission request with "allow once".
  defp allow!(%{permission: %{"id" => id}, state: {sid, state}}) do
    {resp, updates, state} =
      Server.handle_message(
        %{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
        },
        state
      )

    turn(resp, updates, {sid, state})
  end

  defp turn(resp, updates, state) do
    said =
      for %{"method" => "session/update", "params" => %{"update" => update}} <- updates,
          update["sessionUpdate"] == "agent_message_chunk",
          into: "",
          do: update["content"]["text"]

    %{
      response: resp,
      said: said,
      permission: Enum.find(updates, &(&1["method"] == "session/request_permission")),
      state: state
    }
  end
end
