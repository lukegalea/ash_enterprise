defmodule AshEnterprise.Bpmn.IncidentTriagePackTest do
  @moduledoc """
  What happens at three in the morning (q49): an alert opens an incident, and the
  `incident_triage` pack's recipe gives the tenant's On-call role one triage task, on the
  task list, per incident. A duplicate alert joins the open incident instead of opening a
  second.

  The alerts here are `alert.firing` and `alert.resolved` occurrences recorded directly, as
  the alert webhook records them, so each case names its own rule and time.
  `test/ash_enterprise_web/incident_webhook_test.exs` sends them through the webhook.

  The refusals come first: drafts start nothing, another tenant's alert starts nothing, an
  occurrence that is not an alert or names no rule opens no incident, a resolution with
  nothing open does nothing, and a person not on call neither sees nor decides the task.
  Then the task itself, the duplicate that joins, and what closes an incident.

  This proves that an alert reaching the application becomes an assigned, audited task. It
  does not prove anyone is woken: the rota, the pager and the alert relay are the owner's.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 1, actor: 2]

  require Ash.Query

  alias AshEnterprise.Automation
  alias AshEnterprise.Automation.Incident

  alias AshEnterprise.Bpmn.{
    Definition,
    Dispatch,
    HumanTask,
    Instance,
    Subscription,
    TaskCandidate
  }

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.{Role, UserRole}

  @pack "incident_triage"
  @process "incident.triage"
  @recipe "incident.triage.opened"
  @source "urn:ash-enterprise:alerts:test"

  # A tenant with the pack installed, a person on call and a person who is not.
  defp installed_tenant! do
    admin = tenant!()
    on_call = on_call!(admin)
    bystander = colleague!(admin)

    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)

    %{admin: admin, on_call: on_call, bystander: bystander, tenant: admin.tenant}
  end

  # A colleague given the starter On-call role, with an actor built after the assignment.
  defp on_call!(admin) do
    person = colleague!(admin)
    role_name = Seeder.on_call_role()

    [role] =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read!(authorize?: false, tenant: admin.tenant)

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: person.user.id,
        role_id: role.id,
        scoping_business_unit_id: admin.business_unit.id
      },
      tenant: admin.tenant,
      authorize?: false
    )
    |> Ash.create!()

    %{person | actor: actor(person.user, admin.tenant)}
  end

  defp publish!(ctx) do
    opts = [actor: ctx.admin.actor, tenant: ctx.tenant]

    [process] = drafts(Definition, @process, ctx.tenant)
    Definition.publish!(process, opts)

    [recipe] = drafts(Subscription, @recipe, ctx.tenant)
    Subscription.publish!(recipe, opts)
  end

  defp drafts(resource, key, tenant) do
    resource
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  # An alert as the webhook records it: one occurrence, written by the platform.
  defp alert!(tenant, type, data) do
    Automation.record_occurrence!(
      %{
        event_id: "test:#{System.unique_integer([:positive])}",
        source: @source,
        type: type,
        subject: nil,
        time: DateTime.utc_now(),
        data: data
      },
      actor: SystemActor.oban(),
      tenant: tenant
    )
  end

  defp firing!(tenant, rule \\ "rule-1"),
    do:
      alert!(tenant, "alert.firing", %{
        "provider" => "signoz",
        "alertname" => "Health checks failing",
        "severity" => "critical",
        "rule_id" => rule
      })

  defp resolved!(tenant, rule \\ "rule-1"),
    do: alert!(tenant, "alert.resolved", %{"provider" => "signoz", "rule_id" => rule})

  # The sweep as production runs it, then the advances it enqueued.
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

  defp incidents(tenant), do: Incident |> Ash.Query.sort(:first_alert_at) |> all_q(tenant)
  defp all_q(query, tenant), do: Ash.read!(query, authorize?: false, tenant: tenant)

  defp open_tasks(tenant),
    do: HumanTask |> Ash.Query.filter(status == :open) |> all_q(tenant)

  defp task_list(person, tenant) do
    HumanTask
    |> Ash.Query.filter(status == :open)
    |> Ash.read!(actor: fresh(person, tenant), tenant: tenant)
  end

  # The actor as a request builds it now: what a person may act on is precomputed when the
  # request starts, so a task written after an actor was built is not in its context.
  defp fresh(person, tenant), do: actor(person.user, tenant)

  defp work(task, action, args, person, tenant) do
    HumanTask
    |> Ash.ActionInput.for_action(action, Map.put(args, :record_id, task.id),
      actor: fresh(person, tenant),
      tenant: tenant
    )
    |> Ash.run_action()
  end

  # ── refusals ──────────────────────────────────────────────────────────

  test "an alert opens an incident, and nothing is triaged before a person publishes" do
    ctx = installed_tenant!()

    firing!(ctx.tenant)
    sweep!(ctx.tenant)

    assert [%{status: :open, alert_count: 1}] = incidents(ctx.tenant)
    assert all(Dispatch, ctx.tenant) == []
    assert all(Instance, ctx.tenant) == []
    assert open_tasks(ctx.tenant) == []
  end

  test "another tenant's alert opens nothing in a tenant that published the pack" do
    published = installed_tenant!()
    publish!(published)

    other = installed_tenant!()
    firing!(other.tenant)

    sweep!(other.tenant)
    sweep!(published.tenant)

    assert incidents(published.tenant) == []
    assert all(Dispatch, published.tenant) == []
    assert open_tasks(published.tenant) == []

    # The other tenant has its incident, and no recipe to triage it.
    assert [_incident] = incidents(other.tenant)
    assert open_tasks(other.tenant) == []
  end

  test "an occurrence that is not an alert, or an alert naming no rule, opens no incident" do
    ctx = installed_tenant!()
    publish!(ctx)

    alert!(ctx.tenant, "user.deactivated", %{})
    alert!(ctx.tenant, "alert.firing", %{"alertname" => "No provider"})
    alert!(ctx.tenant, "alert.firing", %{"provider" => "signoz", "severity" => "critical"})
    sweep!(ctx.tenant)

    assert incidents(ctx.tenant) == []
    assert all(Instance, ctx.tenant) == []
    assert open_tasks(ctx.tenant) == []
  end

  test "a resolution with no incident open for its rule changes nothing" do
    ctx = installed_tenant!()
    publish!(ctx)

    resolved!(ctx.tenant)
    firing!(ctx.tenant, "rule-a")
    resolved!(ctx.tenant, "rule-b")

    assert [%{key: "signoz:rule-a", status: :open}] = incidents(ctx.tenant)
  end

  test "with nobody on call, the triage task has nobody, and a finding says so" do
    admin = tenant!()
    {:ok, _} = Subscription.install_pack(@pack, actor: admin.actor, tenant: admin.tenant)
    ctx = %{admin: admin, tenant: admin.tenant}
    publish!(ctx)

    firing!(ctx.tenant)
    sweep!(ctx.tenant)

    assert [task] = open_tasks(ctx.tenant)

    assert TaskCandidate
           |> Ash.Query.filter(task_id == ^task.id)
           |> Ash.read!(authorize?: false, tenant: ctx.tenant) == []

    {:ok, findings} =
      AshCompliance.Domain.findings_for_organization(ctx.tenant, authorize?: false)

    assert [_ | _] =
             unassignable =
             Enum.filter(
               findings,
               &(&1.subject_type ==
                   AshEnterprise.Bpmn.Changes.RecordUnassignableFinding.subject_type())
             )

    assert Enum.all?(unassignable, &(&1.subject_id == task.id and &1.severity == :high))
  end

  test "no person may write an incident, not even an administrator" do
    ctx = installed_tenant!()
    firing!(ctx.tenant)
    [incident] = incidents(ctx.tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             Automation.open_incident(
               %{key: "signoz:forged", at: DateTime.utc_now()},
               actor: ctx.admin.actor,
               tenant: ctx.tenant
             )

    for person <- [ctx.admin, ctx.on_call] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.close_incident(incident, :alert_resolved,
                 actor: person.actor,
                 tenant: ctx.tenant
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.join_incident(incident, %{at: DateTime.utc_now()},
                 actor: person.actor,
                 tenant: ctx.tenant
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               Automation.resolve_incident_series(incident, "fp-forged",
                 actor: person.actor,
                 tenant: ctx.tenant
               )
    end
  end

  # ── the task ──────────────────────────────────────────────────────────

  test "an alert gives the On-call role one triage task, which a person not on call cannot see or take" do
    ctx = installed_tenant!()
    publish!(ctx)

    firing!(ctx.tenant)
    sweep!(ctx.tenant)

    [incident] = incidents(ctx.tenant)

    assert %{key: "signoz:rule-1", title: "Health checks failing", severity: "critical"} =
             incident

    assert [%{status: :started, instance_id: instance_id}] = all(Dispatch, ctx.tenant)
    instance = Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
    assert instance.subject_id == incident.id
    # No person caused the alert, so the run has no starter. Under human_tasks_only it can
    # only open tasks.
    assert instance.started_by_id == nil

    assert [task] = open_tasks(ctx.tenant)

    candidates =
      TaskCandidate
      |> Ash.Query.filter(task_id == ^task.id)
      |> all_q(ctx.tenant)
      |> Enum.map(& &1.principal_id)

    assert ctx.on_call.user.id in candidates
    refute ctx.bystander.user.id in candidates

    # Delivered in-app: it is on the on-call person's task list, and not on the bystander's.
    assert [%{id: listed}] = task_list(ctx.on_call, ctx.tenant)
    assert listed == task.id
    assert task_list(ctx.bystander, ctx.tenant) == []
    assert {:error, _refused} = work(task, :claim_task, %{}, ctx.bystander, ctx.tenant)

    # The person on call reads the incident the task is about, and resolves it.
    assert [%{id: read_id}] =
             Ash.read!(Incident, actor: fresh(ctx.on_call, ctx.tenant), tenant: ctx.tenant)

    assert read_id == incident.id

    assert {:ok, _} = work(task, :claim_task, %{}, ctx.on_call, ctx.tenant)
    assert {:ok, _} = work(task, :complete_task, %{outcome: :resolved}, ctx.on_call, ctx.tenant)

    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end

    assert open_tasks(ctx.tenant) == []

    assert %{status: :completed, outcome: "resolved"} =
             Ash.get!(Instance, instance_id, authorize?: false, tenant: ctx.tenant)
  end

  test "a duplicate alert joins the open incident instead of opening a second" do
    ctx = installed_tenant!()
    publish!(ctx)

    firing!(ctx.tenant)
    sweep!(ctx.tenant)
    firing!(ctx.tenant)
    firing!(ctx.tenant)
    sweep!(ctx.tenant)

    assert [%{status: :open, alert_count: 3} = incident] = incidents(ctx.tenant)
    assert DateTime.compare(incident.last_alert_at, incident.first_alert_at) == :gt
    assert [_one] = all(Dispatch, ctx.tenant)
    assert [_one] = all(Instance, ctx.tenant)
    assert [_one] = open_tasks(ctx.tenant)

    # Another rule is another incident, with its own task.
    firing!(ctx.tenant, "rule-2")
    sweep!(ctx.tenant)

    assert [%{key: "signoz:rule-1"}, %{key: "signoz:rule-2", alert_count: 1}] =
             incidents(ctx.tenant)

    assert [_, _] = open_tasks(ctx.tenant)
  end

  test "an incident closes when its alert resolves, or when its triage has finished" do
    ctx = installed_tenant!()
    publish!(ctx)

    # Its alert resolves: closed, and the next firing is a new incident.
    firing!(ctx.tenant, "rule-r")
    resolved!(ctx.tenant, "rule-r")

    assert [%{status: :closed, closed_reason: :alert_resolved, closed_at: %DateTime{}}] =
             incidents(ctx.tenant)

    firing!(ctx.tenant, "rule-r")
    assert [%{status: :closed}, %{status: :open, alert_count: 1}] = incidents(ctx.tenant)

    # Its triage finishes: the incident stays open while the run is running, and the next
    # alert closes it and opens another, with a task of its own.
    firing!(ctx.tenant, "rule-t")
    sweep!(ctx.tenant)

    [task] =
      ctx.tenant
      |> open_tasks()
      |> Enum.filter(fn task ->
        instance = Ash.get!(Instance, task.instance_id, authorize?: false, tenant: ctx.tenant)
        incident = Ash.get!(Incident, instance.subject_id, authorize?: false, tenant: ctx.tenant)
        incident.key == "signoz:rule-t"
      end)

    assert {:ok, _} = work(task, :claim_task, %{}, ctx.on_call, ctx.tenant)
    assert {:ok, _} = work(task, :complete_task, %{outcome: :resolved}, ctx.on_call, ctx.tenant)

    firing!(ctx.tenant, "rule-t")
    sweep!(ctx.tenant)

    by_key = ctx.tenant |> incidents() |> Enum.filter(&(&1.key == "signoz:rule-t"))

    assert [
             %{status: :closed, closed_reason: :triage_concluded, alert_count: 1},
             %{status: :open, alert_count: 1}
           ] = by_key
  end
end
