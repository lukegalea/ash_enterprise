defmodule AshEnterprise.Bpmn.AlertReviewTest do
  @moduledoc """
  The `security_alerts` pack (q38: alerts on declared audited events, and a record that a
  person reviewed each one). Its recipes open a review when an Administrator or a Platform
  Operator is made, directly or through a team (the role assigned to a team, a person
  joining a team that holds it, such a team restored), a break-glass session is approved, an API key is issued, a known
  person's sign-in is refused a third time in a row, or an inbound alert labelled security
  fires. Every other audited write is only logged.

  Refusals and near misses first: drafts run nothing, a published pack does nothing for
  another tenant's events, and the event next to each alarm (a role that is not
  privileged, a session opened but not approved, a key revoked, two refusals, an alert of
  another category or one resolving) opens nothing. Then each alarm opens exactly one
  review, which goes to an administrator other than the people involved.

  The SigNoz rules for the same signals (`devenv/observability/security/alerts/`) are
  checked against the spans the application emits: every span name a rule filters on is one
  this application's actions produce, and the refused sign-in carries the error class the
  rule counts. That proves the rules watch real spans; it does not run SigNoz.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, colleague!: 2]

  require Ash.Query
  require OpenTelemetry.Tracer, as: Tracer

  alias AshEnterprise.Accounts.{ApiKey, Team, TeamMembership, User}
  alias AshEnterprise.Automation.{Occurrence, Occurrences}

  alias AshEnterprise.Bpmn.{
    Definition,
    Dispatch,
    HumanTask,
    Instance,
    Subscription,
    TaskCandidate
  }

  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.{ActorContext, BreakGlassSession, Role, TeamRole, UserRole}
  alias AshEnterprise.Telemetry.TraceSink
  alias AshEnterprise.Test.DailyFixtures

  @pack "security_alerts"
  @process "security.review_alert"
  @password "password1234"
  @break_glass_grants [
    {BreakGlassSession, :create, :global},
    {BreakGlassSession, :write, :global}
  ]

  setup do
    %{tasks_before: MapSet.new(Task.Supervisor.children(AshEnterprise.TaskSupervisor))}
  end

  # ── a tenant with the pack ───────────────────────────────────────────────

  # The tenant's administrator installs the pack; a second administrator reviews.
  defp installed! do
    admin = tenant!()
    reviewer = colleague!(admin, admin?: true)
    newcomer = colleague!(admin)

    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    %{admin: admin, reviewer: reviewer, newcomer: newcomer, tenant: admin.tenant}
  end

  # A person publishes the pack's process, then every recipe: the only way it goes live.
  defp publish!(ctx) do
    opts = [actor: ctx.admin.actor, tenant: ctx.tenant]

    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)

    for recipe <- all_drafts(Subscription, ctx.tenant), do: Subscription.publish!(recipe, opts)

    ctx
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp all_drafts(resource, tenant) do
    resource
    |> Ash.Query.filter(status == :draft and contains(key, "security_alerts."))
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp unique, do: System.unique_integer([:positive])

  # ── the events ───────────────────────────────────────────────────────────

  defp role!(ctx, name) do
    Role
    |> Ash.Changeset.for_create(:create, %{name: name},
      actor: SystemActor.seed(),
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp administrator_role!(ctx) do
    Role
    |> Ash.Query.filter(name == "Administrator")
    |> Ash.read_one!(authorize?: false, tenant: ctx.tenant)
  end

  defp assign!(ctx, user, role) do
    UserRole
    |> Ash.Changeset.for_create(:assign, %{user_id: user.id, role_id: role.id},
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp owner_team!(ctx) do
    Team
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Platform team #{unique()}",
        team_type: :owner,
        owning_business_unit_id: ctx.admin.business_unit.id
      },
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp assign_to_team!(ctx, team, role) do
    TeamRole
    |> Ash.Changeset.for_create(:assign, %{team_id: team.id, role_id: role.id},
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp join!(ctx, team, user) do
    TeamMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: user.id},
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp administrator_of?(ctx, user) do
    context = ActorContext.build(user, tenant: ctx.tenant)
    ActorContext.grant(context, Role, :write).global?
  end

  # A member who may open and approve break-glass sessions.
  defp break_glass_member!(ctx, label),
    do: DailyFixtures.member!(ctx.admin, "#{label} #{unique()}", @break_glass_grants)

  defp open_session!(ctx, operator, approver, subject) do
    BreakGlassSession
    |> Ash.Changeset.for_create(
      :open,
      %{
        subject_id: subject.user.id,
        approver_id: approver.user.id,
        reason: "SYNTHETIC: a customer reported a failed import",
        duration_minutes: 30
      },
      actor: operator.actor
    )
    |> Ash.create!()
  end

  defp approve!(session, approver) do
    session
    |> Ash.Changeset.for_update(:approve, %{}, actor: approver.actor)
    |> Ash.update!()
  end

  defp issue_key!(user) do
    ApiKey
    |> Ash.Changeset.for_create(
      :issue,
      %{
        user_id: user.id,
        name: "SYNTHETIC key #{unique()}",
        expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp sign_in(email, password) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    AshAuthentication.Strategy.action(strategy, :sign_in, %{
      "email" => to_string(email),
      "password" => password
    })
  end

  defp refuse!(person, times) do
    for _ <- 1..times, do: assert({:error, _} = sign_in(person.user.email, "not-the-password"))
  end

  defp alert!(ctx, overrides) do
    alert =
      Map.merge(
        %{
          event_id: "signoz:#{unique()}:2026-11-12T00:00:00Z:firing",
          type: "alert.firing",
          subject: nil,
          data: %{"provider" => "signoz", "alertname" => "SYNTHETIC", "category" => "security"}
        },
        overrides
      )

    assert {:ok, 1} = Occurrences.record_alerts(ctx.tenant, "signoz", [alert])
  end

  # Waits for the refusal tasks this test started, by monitor and not by sleeping.
  defp await_tasks(%{tasks_before: before}) do
    for pid <- Task.Supervisor.children(AshEnterprise.TaskSupervisor),
        not MapSet.member?(before, pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> flunk("a recording task did not finish")
      end
    end

    :ok
  end

  # ── the sweep and what it left ───────────────────────────────────────────

  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end

    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  defp all(resource, tenant), do: Ash.read!(resource, authorize?: false, tenant: tenant)

  defp started(tenant), do: Dispatch |> all(tenant) |> Enum.filter(&(&1.status == :started))

  defp reviews(tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp candidates(task, tenant) do
    TaskCandidate
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.map(& &1.principal_id)
  end

  # One review, opened by `recipe`, offered to the reviewer and to none of `involved`.
  defp one_review!(ctx, recipe, involved) do
    assert [dispatch] = started(ctx.tenant)
    assert [task] = reviews(ctx.tenant)

    recipe_row =
      Ash.get!(Subscription, dispatch.subscription_id, authorize?: false, tenant: ctx.tenant)

    assert recipe_row.key == recipe

    candidates = candidates(task, ctx.tenant)
    assert ctx.reviewer.user.id in candidates

    for person <- involved do
      refute person.user.id in candidates
      assert person.user.id in task.excluded_principal_ids
    end

    task
  end

  defp nothing!(tenant) do
    assert started(tenant) == []
    assert reviews(tenant) == []
  end

  # ── refused and near misses ──────────────────────────────────────────────

  describe "nothing opens a review" do
    test "before a person publishes: the pack installs as drafts that run nothing", ctx do
      tenant = installed!()

      assign!(tenant, tenant.newcomer.user, administrator_role!(tenant))
      issue_key!(tenant.newcomer.user)
      refuse!(tenant.newcomer, 3)
      await_tasks(ctx)
      alert!(tenant, %{})
      sweep!(tenant.tenant)

      assert all(Dispatch, tenant.tenant) == []
      assert all(Instance, tenant.tenant) == []
      assert reviews(tenant.tenant) == []
    end

    test "for another tenant's events, when only one tenant published", ctx do
      published = installed!() |> publish!()
      other = installed!()

      assign!(other, other.newcomer.user, administrator_role!(other))
      issue_key!(other.newcomer.user)
      refuse!(other.newcomer, 3)
      await_tasks(ctx)
      alert!(other, %{})

      sweep!(other.tenant)
      sweep!(published.tenant)

      nothing!(published.tenant)
      nothing!(other.tenant)

      # The other tenant's facts are recorded in its own chain and no other.
      assert Ash.read!(Occurrence, actor: SystemActor.oban(), tenant: published.tenant) == []
    end

    test "for a role that is neither Administrator nor Platform Operator" do
      ctx = installed!() |> publish!()

      for name <- [
            "Report Reader #{unique()}",
            "Administrator Assistant #{unique()}",
            "Platform Operator Deputy #{unique()}"
          ] do
        assign!(ctx, ctx.newcomer.user, role!(ctx, name))
      end

      sweep!(ctx.tenant)
      nothing!(ctx.tenant)
    end

    test "for a team given a role that is not privileged, and a person joining it" do
      ctx = installed!() |> publish!()
      team = owner_team!(ctx)

      assign_to_team!(ctx, team, role!(ctx, "Report Reader #{unique()}"))
      join!(ctx, team, ctx.newcomer.user)

      sweep!(ctx.tenant)
      nothing!(ctx.tenant)
    end

    test "for a person added again to a team holding Administrator they are already in" do
      ctx = installed!()
      team = owner_team!(ctx)
      assign_to_team!(ctx, team, administrator_role!(ctx))
      join!(ctx, team, ctx.newcomer.user)
      publish!(ctx)

      # Directory sync adds people again routinely: the same membership, nothing granted.
      join!(ctx, team, ctx.newcomer.user)
      assign_to_team!(ctx, team, administrator_role!(ctx))

      sweep!(ctx.tenant)
      nothing!(ctx.tenant)
    end

    test "for a break-glass session opened but not approved" do
      ctx = installed!() |> publish!()
      operator = break_glass_member!(ctx, "Operator")
      approver = break_glass_member!(ctx, "Approver")

      open_session!(ctx, operator, approver, ctx.newcomer)
      sweep!(ctx.tenant)

      nothing!(ctx.tenant)
    end

    test "for an API key revoked, as opposed to issued" do
      ctx = installed!()
      key = issue_key!(ctx.newcomer.user)
      publish!(ctx)

      Ash.destroy!(key, authorize?: false)
      sweep!(ctx.tenant)

      nothing!(ctx.tenant)
    end

    test "for a first and a second refused sign-in", ctx do
      tenant = installed!() |> publish!()

      refuse!(tenant.newcomer, 2)
      await_tasks(ctx)
      sweep!(tenant.tenant)

      assert length(Ash.read!(Occurrence, actor: SystemActor.oban(), tenant: tenant.tenant)) == 2
      nothing!(tenant.tenant)
    end

    test "for an inbound alert of another category, or one resolving" do
      ctx = installed!() |> publish!()

      alert!(ctx, %{data: %{"provider" => "signoz", "category" => "error"}})
      alert!(ctx, %{data: %{"provider" => "signoz"}})

      alert!(ctx, %{
        event_id: "signoz:#{unique()}:2026-11-12T00:00:00Z:resolved",
        type: "alert.resolved"
      })

      sweep!(ctx.tenant)
      nothing!(ctx.tenant)
    end
  end

  # ── a review nobody else can take ───────────────────────────────────────

  describe "a review nobody but the people involved could take" do
    # A small tenant's only administrator is involved in every review: the exclusions leave
    # nobody. The review is still written, falls back to the tenant's Platform Operator
    # when it has one (`AssignmentResolver.no_eligible_candidate/2`), and a finding against
    # the pack's controls says nobody could take it.

    test "the sole administrator's own API key: the review has nobody, and a finding says so" do
      admin = tenant!()
      {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)
      ctx = publish!(%{admin: admin, tenant: admin.tenant})

      issue_key!(admin.user)
      sweep!(ctx.tenant)

      assert [task] = reviews(ctx.tenant)
      assert candidates(task, ctx.tenant) == []
      assert admin.user.id in task.excluded_principal_ids

      findings = unassignable_findings(ctx.tenant)
      assert findings != []
      assert Enum.all?(findings, &(&1.subject_id == task.id and &1.severity == :high))
      assert findings |> Enum.map(& &1.control_id) |> Enum.all?(&(&1 in pack_controls()))
    end

    test "another tenant's unroutable review files nothing here" do
      quiet = installed!() |> publish!()

      admin = tenant!()
      {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)
      ctx = publish!(%{admin: admin, tenant: admin.tenant})
      issue_key!(admin.user)
      sweep!(ctx.tenant)
      sweep!(quiet.tenant)

      assert unassignable_findings(ctx.tenant) != []
      assert unassignable_findings(quiet.tenant) == []
    end
  end

  defp unassignable_findings(tenant) do
    {:ok, findings} = AshCompliance.Domain.findings_for_organization(tenant, authorize?: false)

    Enum.filter(
      findings,
      &(&1.subject_type == AshEnterprise.Bpmn.Changes.RecordUnassignableFinding.subject_type())
    )
  end

  defp pack_controls do
    {:ok, manifest} = AshEnterprise.Compliance.TemplateMap.manifest(@pack)
    manifest["controls"]
  end

  # ── each alarm opens one review ──────────────────────────────────────────

  describe "a review opens" do
    test "when an Administrator is made, offered to neither the granter nor the grantee" do
      ctx = installed!() |> publish!()

      assignment = assign!(ctx, ctx.newcomer.user, administrator_role!(ctx))
      sweep!(ctx.tenant)

      task =
        one_review!(ctx, "security_alerts.privileged_role_assigned", [ctx.admin, ctx.newcomer])

      assert [%{instance_id: instance_id}] = started(ctx.tenant)
      instance = Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
      assert instance.subject_id == assignment.id

      # The other administrator records whether it was expected.
      assert {:ok, _} =
               HumanTask
               |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
                 actor: ctx.reviewer.actor,
                 tenant: ctx.tenant
               )
               |> Ash.run_action()

      assert %{status: :completed, outcome: "expected"} =
               Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
    end

    test "when a Platform Operator is made" do
      ctx = installed!() |> publish!()

      assign!(ctx, ctx.newcomer.user, role!(ctx, "Platform Operator"))
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.privileged_role_assigned", [ctx.admin, ctx.newcomer])
    end

    test "when Administrator is assigned to a team, offered to neither the granter nor its members" do
      ctx = installed!()
      team = owner_team!(ctx)
      # A member who is already an administrator: leaving them out is the exclusion's doing.
      member = colleague!(ctx.admin, admin?: true)
      join!(ctx, team, member.user)
      join!(ctx, team, ctx.newcomer.user)
      publish!(ctx)

      assignment = assign_to_team!(ctx, team, administrator_role!(ctx))
      assert administrator_of?(ctx, ctx.newcomer.user)
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.privileged_role_assigned_to_team", [
        ctx.admin,
        member,
        ctx.newcomer
      ])

      assert [%{instance_id: instance_id}] = started(ctx.tenant)

      assert Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant).subject_id ==
               assignment.id
    end

    test "when a person joins a team holding Administrator, offered to neither the adder nor them" do
      ctx = installed!()
      team = owner_team!(ctx)
      assign_to_team!(ctx, team, administrator_role!(ctx))
      publish!(ctx)

      refute administrator_of?(ctx, ctx.newcomer.user)
      join!(ctx, team, ctx.newcomer.user)
      assert administrator_of?(ctx, ctx.newcomer.user)

      sweep!(ctx.tenant)
      one_review!(ctx, "security_alerts.privileged_team_joined", [ctx.admin, ctx.newcomer])
    end

    test "when a deleted team holding Administrator is restored" do
      ctx = installed!()
      team = owner_team!(ctx)
      assign_to_team!(ctx, team, administrator_role!(ctx))
      join!(ctx, team, ctx.newcomer.user)
      Ash.destroy!(team, actor: ctx.admin.actor, tenant: ctx.tenant)
      refute administrator_of?(ctx, ctx.newcomer.user)
      publish!(ctx)

      archived =
        AshEnterprise.Accounts.get_archived_team!(team.id,
          actor: ctx.admin.actor,
          tenant: ctx.tenant
        )

      AshEnterprise.Accounts.restore_team!(archived, actor: ctx.admin.actor, tenant: ctx.tenant)
      assert administrator_of?(ctx, ctx.newcomer.user)
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.privileged_team_restored", [ctx.admin, ctx.newcomer])
    end

    test "when a break-glass session is approved, offered to anyone but its operator" do
      ctx = installed!()
      operator = break_glass_member!(ctx, "Operator")
      approver = break_glass_member!(ctx, "Approver")
      # The operator is an administrator too, so leaving them out is the exclusion's doing.
      assign!(ctx, operator.user, administrator_role!(ctx))
      publish!(ctx)

      session = open_session!(ctx, operator, approver, ctx.newcomer)
      approve!(session, approver)
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.break_glass_approved", [operator])

      assert [%{subject: subject, data: data}] =
               Ash.read!(Occurrence, actor: SystemActor.oban(), tenant: ctx.tenant)

      assert subject == operator.user.id
      assert data["session_id"] == session.id
      assert data["acting_as"] == ctx.newcomer.user.id
      assert data["minutes"] == 30
    end

    test "when an API key is issued, offered to anyone but its owner" do
      ctx = installed!()
      owner = colleague!(ctx.admin, admin?: true)
      publish!(ctx)

      key = issue_key!(owner.user)
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.api_key_issued", [owner])

      assert [%{data: data}] =
               Ash.read!(Occurrence, actor: SystemActor.oban(), tenant: ctx.tenant)

      assert data["key_id"] == key.id
      refute Enum.any?(Map.values(data), &(is_binary(&1) and &1 =~ "aek_"))
    end

    test "on the third refused sign-in in a row, once, offered to anyone but that person", ctx do
      tenant = installed!()
      person = colleague!(tenant.admin, admin?: true)
      publish!(tenant)

      refuse!(person, 4)
      await_tasks(ctx)
      sweep!(tenant.tenant)

      one_review!(tenant, "security_alerts.repeated_sign_in_refusals", [person])

      failures =
        Occurrence
        |> Ash.read!(actor: SystemActor.oban(), tenant: tenant.tenant)
        |> Enum.map(& &1.data["failures"])
        |> Enum.sort()

      assert failures == [1, 2, 3, 4]
    end

    test "when an inbound alert labelled security fires" do
      ctx = installed!() |> publish!()

      alert!(ctx, %{})
      sweep!(ctx.tenant)

      one_review!(ctx, "security_alerts.inbound_security_alert", [])
    end
  end

  # ── the SigNoz rules for the same signals ────────────────────────────────

  describe "the SigNoz rules" do
    @rules Path.wildcard(
             Path.expand("../../../devenv/observability/security/alerts/*.json", __DIR__)
           )

    defp rules do
      assert @rules != [], "the security alert rules are where the test looks for them"
      Enum.map(@rules, &(&1 |> File.read!() |> Jason.decode!()))
    end

    defp filter(rule),
      do:
        get_in(rule, [
          "condition",
          "compositeQuery",
          "queries",
          Access.at(0),
          "spec",
          "filter",
          "expression"
        ])

    defp span_names(rule) do
      ~r/'([a-z_]+:[a-z_]+\.[a-z_]+)'/
      |> Regex.scan(filter(rule))
      |> Enum.map(fn [_, name] -> name end)
    end

    defp in_request(fun) do
      Tracer.with_span "test request" do
        fun.()
        OpenTelemetry.Span.trace_id(Tracer.current_span_ctx())
      end
    end

    test "each rule is a security trace rule naming spans the application's actions produce" do
      produced =
        MapSet.new([
          Ash.Domain.Info.span_name(AshEnterprise.Accounts, User, :sign_in_with_password),
          Ash.Domain.Info.span_name(AshEnterprise.Security, UserRole, :assign),
          Ash.Domain.Info.span_name(AshEnterprise.Security, UserRole, :assign_governed),
          Ash.Domain.Info.span_name(AshEnterprise.Accounts, ApiKey, :issue),
          Ash.Domain.Info.span_name(AshEnterprise.Security, BreakGlassSession, :approve)
        ])

      named = rules() |> Enum.flat_map(&span_names/1) |> MapSet.new()

      assert named == produced

      for rule <- rules() do
        assert rule["alertType"] == "TRACES_BASED_ALERT"
        assert rule["labels"]["category"] == "security"
      end
    end

    test "the spans they count are emitted, and a refused sign-in carries the class it counts",
         env do
      ctx = installed!()
      operator = break_glass_member!(ctx, "Operator")
      approver = break_glass_member!(ctx, "Approver")

      trace_id =
        in_request(fn ->
          assign!(ctx, ctx.newcomer.user, administrator_role!(ctx))
          issue_key!(ctx.newcomer.user)
          ctx |> open_session!(operator, approver, ctx.newcomer) |> approve!(approver)
          refuse!(ctx.newcomer, 1)
        end)

      await_tasks(env)

      spans = TraceSink.trace(trace_id).spans
      class = AshEnterprise.Telemetry.Attributes.error_class()

      attributes = fn name ->
        for span <- spans, span.name == name do
          Map.new(span.attributes, fn {key, value} -> {to_string(key), value} end)
        end
      end

      assert [refused | _] = attributes.("accounts:user.sign_in_with_password")
      assert refused[class] == "forbidden"

      for name <- [
            "security:user_role.assign",
            "accounts:api_key.issue",
            "security:break_glass_session.approve"
          ] do
        assert [ok | _] = attributes.(name), "#{name} is in the trace"
        refute Map.has_key?(ok, class)
      end
    end
  end
end
