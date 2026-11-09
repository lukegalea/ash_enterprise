defmodule AshEnterpriseWeb.ExplorerLiveTest.Broken do
  @moduledoc false
  # A source whose database is gone: the trace reports it and leaves its gap entry.
  @behaviour AshAgent.Execution.Source

  @impl true
  def read(_scope, _opts), do: {:error, :database_unavailable}

  @impl true
  def to_entries(_rows), do: []
end

defmodule AshEnterpriseWeb.ExplorerLiveTest do
  @moduledoc """
  The execution explorer (`/app/explorer`, `AshEnterpriseWeb.ExplorerLive`) through the
  real LiveView, on the seeded clinic. The path is the one
  `assets/e2e/execution_explorer.spec.ts` walks in a browser.

  The coordinator's work, under one correlation id: a case opened on a credential and
  routed by the review routing table (the process run, its events and the decision with
  the rule that matched); the licence reader reading another credential's documents (the
  evidence) into findings (the judgments); and that credential's activation, approved by
  a committee member, run and recorded by the registry (the effect).

  From the activation, the explorer reaches its effect, its approval, the decision's
  matched rule, a judgment and the evidence it cites; the timeline, the diagram and the
  detail share one selection, and the timeline carries it alone when the canvas cannot
  draw. Then: a failed evaluation case reaches the run's tool arguments; an erased run's
  steps read as erased; guardrail outcomes are on their logical rows; a long trace pages
  by cursor; and what the viewer may not read, a source that cannot be read, and a trace
  that is not one are each shown as what they are. SYNTHETIC data only.
  """

  use AshEnterpriseWeb.ConnCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{DemoData, RoutingTable}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Explorer}
  alias AshEnterprise.ExecutionSources
  alias AshEnterprise.Platform.{Correlation, Seeder, SystemActor}
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.CaseResult
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Credentialing, as: Tour
  alias AshEnterprise.Showcase.Release
  alias AshEnterprise.Test.Execution.{FakeBoard, Runs}
  alias AshEnterpriseWeb.ExplorerLive

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @number "DEMO-PT-0001"
  @referral "AshEnterprise.Test.Execution.ReferralBoard.refer_unchecked"

  setup do
    TestJobs.clear()
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)
    %{admin: admin, tenant: admin.tenant, clinic: clinic}
  end

  defp sign_in(user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp actor(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  # Steps and tool calls run as their jobs do, until nothing is left.
  defp drain!(rounds \\ 12)
  defp drain!(0), do: :ok

  defp drain!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: drain!(rounds - 1),
      else: :ok
  end

  # The coordinator's work under one correlation id (see the moduledoc).
  defp work!(%{clinic: clinic, tenant: tenant}) do
    correlation_id = Ash.UUID.generate()
    coordinator = actor(clinic.coordinator, tenant)
    credential = Enum.find(clinic.credentials, &(&1.number == @number))

    Correlation.with_correlation(correlation_id, fn ->
      {:ok, %{"instance_id" => instance_id}} =
        Credentialing.open_case(clinic.case_credential.id, actor: coordinator, tenant: tenant)

      RoutingTable.publish_next!(tenant)
      instance = Ash.get!(AshEnterprise.Bpmn.Instance, instance_id, authorize?: false)
      {:ok, {_route, _version}} = RoutingTable.route(tenant, instance)

      {:ok, run} = Tour.start_reading(credential.id, coordinator)
      drain!()

      row =
        Execution.invoke!(
          @activate,
          %{"id" => credential.id},
          %{key: "explorer:activate:#{credential.id}"},
          actor: coordinator,
          tenant: tenant
        )

      approve!(row, hd(clinic.committee), tenant)
      Execution.apply_invocation_decision!(row, oban(tenant))
      drain!()
      assert Execution.get_invocation!(row.id, oban(tenant)).status == :succeeded

      %{
        correlation_id: correlation_id,
        run: run,
        activation: row,
        instance_id: instance_id,
        credential: credential
      }
    end)
  end

  defp approve!(row, member, tenant) do
    row_id = row.id
    approval = Approval.key()

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row_id and node_id == ^approval)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    {:ok, _} =
      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
        actor: actor(member, tenant),
        tenant: tenant
      )
      |> Ash.run_action()
  end

  defp flush_pushes do
    receive do
      {_ref, {:push_event, "highlight", _payload}} -> flush_pushes()
    after
      0 -> :ok
    end
  end

  defp row(ref), do: "#timeline [data-ref='#{ref}']"

  defp select!(view, ref) do
    view |> element(row(ref)) |> render_click()
    assert has_element?(view, "#explorer-detail[data-ref='#{ref}']")
    assert has_element?(view, row(ref) <> "[aria-current=true]")
    view
  end

  defp refs(view, selector), do: attribute(view, selector, "data-ref")

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  describe "one time zone" do
    test "timeline rows and the detail panel read in the display zone", ctx do
      previous = Application.get_env(:ash_enterprise, :display_time_zone)
      Application.put_env(:ash_enterprise, :display_time_zone, "Pacific/Auckland")
      on_exit(fn -> Application.put_env(:ash_enterprise, :display_time_zone, previous) end)

      %{correlation_id: correlation_id} = work!(ctx)

      {:ok, view, _html} =
        live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{correlation_id: correlation_id}}")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#timeline [data-row=entry] time")

      assert Enum.count(rows) > 0

      for row <- rows do
        [iso] = LazyHTML.attribute(row, "datetime")
        {:ok, at, _} = DateTime.from_iso8601(iso)
        assert LazyHTML.text(row) |> String.trim() == AshEnterprise.Platform.LocalTime.clock(at)
        refute AshEnterprise.Platform.LocalTime.clock(at) == Calendar.strftime(at, "%H:%M:%S")
      end

      [ref | _] = refs(view, "#timeline [data-row=entry]")
      select!(view, ref)

      [iso] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#timeline [data-ref='#{ref}'] time")
        |> LazyHTML.attribute("datetime")

      {:ok, at, _} = DateTime.from_iso8601(iso)

      assert has_element?(
               view,
               "#explorer-detail dd",
               AshEnterprise.Platform.LocalTime.stamp_seconds(at)
             )
    end
  end

  describe "the navigation path" do
    test "from the activation's effect to its approval, the matched rule, the judgment and the evidence",
         ctx do
      %{activation: activation, correlation_id: correlation_id} = work!(ctx)
      {:ok, view, _html} = live(sign_in(ctx.admin.user), ~p"/app/explorer")

      # Where to start: the latest work the viewer may read.
      activation_ref = "invocation:#{activation.id}"
      assert has_element?(view, "#explorer-recent a[data-ref='#{activation_ref}']")
      view |> element("#explorer-recent a[data-ref='#{activation_ref}']") |> render_click()
      assert_patch(view, ~p"/app/explorer?#{%{root: activation_ref}}")

      # The activation's own rows: the operation, its attempt, its effect and approval.
      effect_ref = "effect:#{activation.id}"
      select!(view, effect_ref)
      assert has_element?(view, "#detail-record[data-record=effect]")
      assert has_element?(view, "#detail-run-mode[data-run-environment=live]")

      assert has_element?(view, "#detail-parent [data-ref='#{activation_ref}']")
      view |> element("#detail-parent [data-ref='#{activation_ref}']") |> render_click()
      assert has_element?(view, "#explorer-detail[data-ref='#{activation_ref}']")

      [approval_ref] = refs(view, "#detail-children [data-ref^='human_task:']")
      view |> element("#detail-children [data-ref='#{approval_ref}']") |> render_click()
      assert has_element?(view, "#detail-record[data-record=human_task]")
      assert has_element?(view, "#detail-record", "approved")

      # Everything recorded with the activation: the decision, the judgments, the evidence.
      select!(view, activation_ref)
      view |> element("#detail-correlation a") |> render_click()
      assert_patch(view, ~p"/app/explorer?#{%{correlation_id: correlation_id}}")

      [decision_ref | _] = refs(view, "#timeline [data-kind=decision]")
      select!(view, decision_ref)
      assert has_element?(view, "#detail-record[data-record=evaluation]", "rule_route")

      [judgment_ref | _] = refs(view, "#timeline [data-ref^='judgment:']")
      select!(view, judgment_ref)
      assert has_element?(view, "#detail-record[data-record=judgment]")
      assert has_element?(view, "#detail-evidence li")

      [evidence_ref | _] = refs(view, "#timeline [data-kind=observation][data-ref^='step:']")
      select!(view, evidence_ref)
      assert has_element?(view, "#detail-record[data-record=step]", "tool")

      # Every row is a button: the timeline is reachable from the keyboard.
      assert refs(view, "#timeline li > :not(button)") == []
      assert has_element?(view, "#timeline[role=log]")
    end

    test "the timeline, the diagram and the detail share one selection, and the timeline keeps it without the canvas",
         ctx do
      %{correlation_id: correlation_id, instance_id: instance_id} = work!(ctx)

      {:ok, view, _html} =
        live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{correlation_id: correlation_id}}")

      # The process run is in the trace, drawn from the definition it pinned.
      assert has_element?(view, row("process_instance:#{instance_id}"))
      assert has_element?(view, "#explorer-bpmn-#{instance_id}[phx-hook=AshBpmnViewer]")

      # A process event on an element (the run's own start is on none): selected on the
      # timeline, highlighted on the diagram, in the detail.
      {event_ref, node} =
        view
        |> refs("#timeline [data-kind=process_event]")
        |> Enum.find_value(fn ref ->
          select!(view, ref)

          case attribute(view, "#diagram-selection", "data-node") do
            [node] -> {ref, node}
            [] -> nil
          end
        end)

      assert_push_event(view, "highlight", %{node_ids: [^node]})
      assert has_element?(view, "#detail-record[data-record=process_event]", node)
      flush_pushes()

      # An entry that is not on the diagram clears the highlight.
      select!(view, "process_instance:#{instance_id}")
      assert has_element?(view, "#diagram-selection:not([data-node])")
      assert_push_event(view, "highlight", %{node_ids: []})

      # The canvas cannot draw: the page says so, and the timeline carries the selection.
      render_hook(view, "import_error", %{"message" => "no canvas"})
      assert has_element?(view, "#diagram-unavailable")
      select!(view, event_ref)
      assert has_element?(view, "#diagram-selection[data-node='#{node}']")

      # The selection is in the URL, so it survives a reload and can be shared.
      {:ok, reloaded, _html} =
        live(
          sign_in(ctx.admin.user),
          ~p"/app/explorer?#{%{correlation_id: correlation_id, selected: event_ref}}"
        )

      assert has_element?(reloaded, "#explorer-detail[data-ref='#{event_ref}']")
      assert has_element?(reloaded, row(event_ref) <> "[aria-current=true]")
    end
  end

  test "from a failed evaluation case, the run's tool calls and their arguments (AI-19)", ctx do
    director = actor(ctx.clinic.director, ctx.tenant)
    {:ok, _suite_run} = Release.measure(director)
    settle!()

    failed =
      CaseResult
      |> Ash.Query.filter(status == :failed and not is_nil(run_id))
      |> Ash.read!(authorize?: false, tenant: ctx.tenant)
      |> List.first()

    assert failed, "the candidate's injection case fails"
    run_ref = "run:#{failed.run_id}"

    {:ok, view, _html} = live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{root: run_ref}}")

    result_ref = "case_result:#{failed.id}"
    select!(view, result_ref)
    assert has_element?(view, "#detail-status[data-status=failed]")
    view |> element("#detail-run a") |> render_click()
    assert has_element?(view, "#explorer-detail[data-ref='#{run_ref}']")

    # A test run says it is one.
    assert has_element?(view, "#detail-run-mode[data-run-environment=test]")
    refute has_element?(view, "#detail-run-mode[data-run-environment=live]")

    # The model turn that called tools: the calls, with the arguments the model asked for.
    [turn | _] = refs(view, "#timeline [data-kind=proposal]")
    select!(view, turn)
    assert has_element?(view, "#detail-calls [data-args=readable]")
  end

  test "an erased run's steps read as erased, never as empty (F11)", ctx do
    %{run: run, credential: credential} = work!(ctx)
    Seeder.grant_platform_operator(ctx.admin.user)
    operator = actor(ctx.admin.user, ctx.tenant)
    {:ok, _shredded} = Tour.erase_clinician(credential.id, operator)

    {:ok, view, _html} =
      live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{root: "run:#{run.id}"}}")

    steps = refs(view, "#timeline [data-ref^='step:']")
    assert steps != []
    assert refs(view, "#timeline [data-ref^='step:'][data-recorded=true]") == []

    for step <- steps,
        do: assert(has_element?(view, row(step) <> " [data-not-recorded]", "erased"))

    [turn | _] = refs(view, "#timeline [data-kind=proposal]")
    select!(view, turn)
    assert has_element?(view, "#detail-not-recorded", "erased")
    assert has_element?(view, "#detail-calls [data-args=erased]")
    refute has_element?(view, "#detail-calls [data-args=readable]")
  end

  test "guardrail outcomes are on their logical rows (AI-15)", ctx do
    rejected =
      Execution.Invocation
      |> Ash.Query.filter(status == :rejected)
      |> Ash.read!(authorize?: false, tenant: ctx.tenant)
      |> List.first()

    assert rejected, "the seed's rejected activation"

    {:ok, view, _html} =
      live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{root: "invocation:#{rejected.id}"}}")

    ref = "invocation:#{rejected.id}"

    assert has_element?(
             view,
             row(ref) <> "[data-kind=logical_operation][data-status=cancelled]",
             "rejected"
           )

    id = Ash.UUID.generate()
    run = Runs.recorded!(ctx.admin, id)
    Runs.model_call!("run:#{run.id}:1", id, %{outcome: :refused})

    {:ok, view, _html} =
      live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{correlation_id: id}}")

    assert has_element?(
             view,
             "#timeline [data-kind=model_call][data-status=cancelled]",
             "refused"
           )
  end

  test "a long trace pages by cursor, and every entry is read once (QX-06)", ctx do
    id = Ash.UUID.generate()
    run = Runs.recorded!(ctx.admin, id)
    {_name, _module, source_opts} = List.keyfind(ExecutionSources.all(), :model_call, 0)
    total = source_opts[:limit] + 5

    for n <- 1..total do
      Runs.model_call!("run:#{run.id}:#{n}", id, %{
        input_tokens: 1,
        output_tokens: 1,
        duration_ms: 1
      })
    end

    {:ok, view, _html} =
      live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{correlation_id: id}}")

    assert length(refs(view, "#timeline [data-kind=model_call]")) == source_opts[:limit]
    assert has_element?(view, "#timeline-paging", "model_call")

    view |> element("#timeline-more") |> render_click()

    read = refs(view, "#timeline [data-kind=model_call]")
    assert length(read) == total
    assert length(Enum.uniq(read)) == total
    refute has_element?(view, "#timeline-paging")
  end

  test "what a person did about a request is under it, with why, and the rerun under the request it reruns",
       ctx do
    FakeBoard.start!()
    FakeBoard.mode(:lose_ack)
    nurse = member!(ctx.admin, "Nurse #{System.unique_integer([:positive])}", [])
    system = [actor: SystemActor.oban(), tenant: ctx.tenant]
    admin = [actor: ctx.admin.actor, tenant: ctx.tenant]

    row =
      Execution.invoke!(
        @referral,
        %{"patient" => "SYNTHETIC patient #{System.unique_integer([:positive])}"},
        %{key: "refer:#{System.unique_integer([:positive])}"},
        actor: nurse.actor,
        tenant: ctx.tenant
      )

    assert :outcome_unknown = Execution.execute_invocation!(%{"id" => row.id}, system)
    assert :resolution_requested = Execution.reconcile_invocation!(%{"id" => row.id}, system)
    FakeBoard.mode(:accept)

    ref = "invocation:#{row.id}"
    path = ~p"/app/explorer?#{%{root: ref, selected: ref}}"

    # Uncertain, never a pass, with the way to step in.
    {:ok, view, _html} = live(sign_in(ctx.admin.user), path)
    assert has_element?(view, row(ref) <> "[data-status=uncertain]")
    assert has_element?(view, "#detail-recovery a[href='/app/recovery/#{row.id}']")

    Execution.resolve_invocation!(row.id, :failed, "The board has no such referral.", admin)
    Oban.drain_queue(queue: :execution, with_recursion: true)
    intervention = Execution.rerun_invocation!(row.id, "Refer again, by hand.", admin)

    {:ok, view, _html} = live(sign_in(ctx.admin.user), path)
    [settled, asked] = refs(view, "#timeline [data-ref^='intervention:']")

    select!(view, settled)

    assert has_element?(
             view,
             "#detail-record[data-record=intervention]",
             "The board has no such referral."
           )

    assert has_element?(view, "#detail-parent [data-ref='#{ref}']")

    select!(view, asked)
    assert has_element?(view, "#detail-record", "Refer again, by hand.")
    view |> element("#detail-rerun a") |> render_click()

    rerun_ref = "invocation:#{intervention.rerun_id}"
    assert has_element?(view, "#explorer-detail[data-ref='#{rerun_ref}']")
    assert has_element?(view, "#detail-rerun-of a")
    assert has_element?(view, "#detail-run-mode[data-run-environment=live]")
  end

  test "an argument its target marks sensitive is named, never shown", ctx do
    [credential | _] = ctx.clinic.credentials
    secret = "SYNTHETIC-#{System.unique_integer([:positive])}"

    row =
      Execution.invoke!(
        "AshEnterprise.Credentialing.Credential.correct",
        %{"id" => credential.id, "number" => secret},
        %{key: "correct:#{System.unique_integer([:positive])}"},
        actor: ctx.admin.actor,
        tenant: ctx.tenant
      )

    ref = "invocation:#{row.id}"

    {:ok, view, _html} =
      live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{root: ref, selected: ref}}")

    assert has_element?(view, "#detail-args [data-sensitive]", "sensitive, not shown")
    assert has_element?(view, "#detail-args", credential.id)
    refute render(view) =~ secret

    # A target that no longer resolves shows none of its values as safe.
    assert AshEnterprise.Execution.ReviewPacket.sensitive_inputs("Nowhere.Gone.act") == :all
  end

  describe "what is not there is not read as there" do
    test "a viewer who may read none of it sees nothing of it", ctx do
      %{correlation_id: correlation_id, activation: activation} = work!(ctx)
      porter = member!(ctx.admin, "Porter #{System.unique_integer([:positive])}", [])

      {:ok, view, _html} = live(sign_in(porter.user), ~p"/app/explorer")
      assert has_element?(view, "#explorer-recent-none")

      {:ok, view, _html} =
        live(sign_in(porter.user), ~p"/app/explorer?#{%{correlation_id: correlation_id}}")

      assert has_element?(view, "#timeline-empty")
      assert refs(view, "#timeline [data-ref]") == []
      assert has_element?(view, "#diagram-none")

      # A selection named in the URL that the trace does not hold selects nothing.
      {:ok, view, _html} =
        live(
          sign_in(porter.user),
          ~p"/app/explorer?#{%{root: "invocation:#{activation.id}", selected: "invocation:#{activation.id}"}}"
        )

      assert has_element?(view, "#detail-none")
      refute has_element?(view, "#detail-record")
    end

    test "a source that cannot be read is an error row naming it, not a gap", ctx do
      {entries, [report]} =
        ExecutionSources.collect(
          [{:broken, __MODULE__.Broken, limit: 5}],
          %{correlation_id: "c", refs: MapSet.new()},
          actor: ctx.admin.actor,
          tenant: ctx.tenant
        )

      assert report.status == :failed
      html = render_component(&ExplorerLive.timeline/1, entries: entries, selected: nil)
      rows = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-ref='source:broken']")

      assert LazyHTML.attribute(rows, "data-row") == ["error"]
      assert LazyHTML.text(rows) =~ "Could not read broken"
      assert LazyHTML.text(rows) =~ "database_unavailable"
      refute html =~ "timeline-empty"
    end

    test "a trace that is not one is an error, never an empty trace", ctx do
      {:ok, view, _html} =
        live(sign_in(ctx.admin.user), ~p"/app/explorer?#{%{root: "run:not-a-uuid"}}")

      assert has_element?(view, "#explorer-error")
      refute has_element?(view, "#timeline-empty")
    end

    test "a record behind an entry that cannot be read says so", ctx do
      opts = [actor: ctx.admin.actor, tenant: ctx.tenant]
      assert Explorer.detail("run:#{Ash.UUID.generate()}", opts) == :unreadable
      assert Explorer.detail("run:not-a-uuid", opts) == :unreadable
      assert Explorer.detail("source:broken", opts) == :none
      assert Explorer.detail("garbage", opts) == :none
    end
  end

  # What the runs' `:step` jobs and their tool calls' `:execute` jobs do, until neither
  # queue has anything left, and then the sweep that scores a suite run whose cases settled.
  defp settle!(rounds \\ 12)
  defp settle!(0), do: :ok

  defp settle!(rounds) do
    steps = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    calls = Oban.drain_queue(queue: :execution, with_recursion: true)

    if steps.success + steps.failure + calls.success + calls.failure > 0,
      do: settle!(rounds - 1),
      else:
        AshOban.Test.schedule_and_run_triggers({Quality.SuiteRun, :finish}, drain_queues?: true)
  end
end
