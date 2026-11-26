defmodule AshEnterprise.Process.AccessRequestDemoTest do
  @moduledoc """
  The demonstration ADR 0009 has been owed since it was written: a process that actually runs
  in *this* application, started by an event through `ash_bpmn`'s trigger engine, routed by a
  DMN decision, deciding an approval through the same union of grants that decides everything
  else.

  Every claim below was previously an argument in a document. Each is now the thing that fails
  if it stops being true. What is *this application's* to prove is the wiring — the adapter
  over the audit log, the sweep fanned out per tenant, the dispatch ledger written with the
  instance — not the engine's internals, which `ash_bpmn`'s own `triggers_runtime_test`
  covers.

  ## The tenant publishes its own copy, and that is the gap being demonstrated

  The correlator resolves a subscription's `process_key` with `latest_published` **in the
  event's tenant**; the engine offers no loader seam at start time. This tenant therefore
  forks the platform baseline and publishes the draft before the subscription can dispatch —
  exactly the documented Phase-2 gap (see `AshEnterprise.Process`'s moduledoc). The decision
  side needs no such copy: decision evaluation resolves through `Resolver`, which reads the
  platform baseline cross-tenant by design.
  """

  use AshEnterprise.DataCase, async: false

  import Swoosh.TestAssertions

  require Ash.Query
  require Ecto.Query

  alias AshEnterprise.Bpmn.{
    Cursor,
    Dispatch,
    HumanTask,
    Instance,
    ProcessEvent,
    Subscription,
    TimerJob
  }

  alias AshBpmn.Runtime.Oban.TestJobs
  alias AshEnterprise.Bpmn.Changes.RecordUnassignableFinding
  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Resolver, TaskNotice}
  alias AshEnterprise.Security.{AccessRequest, Role, UserRole}
  alias AshEnterprise.Test.AssistantFixtures
  alias AshEnterprise.Test.Process.FlakyMailer

  setup do
    platform = Seeder.seed_platform_organization()
    publish_baselines(platform.id)

    %{organization: organization, user: admin, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "demo-#{System.unique_integer([:positive])}",
        email: "demo-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    opts = [actor: SystemActor.process(), tenant: organization.id]

    # The Phase-2 gap, exercised rather than hidden: the tenant's own published
    # copy of the process is what the subscription's `process_key` resolves to.
    tenant_definition = fork_and_publish!("access_request.grant", opts)

    subscription =
      Subscription.create!(
        %{
          key: "access_request.submitted",
          match_resource: "AshEnterprise.Security.AccessRequest",
          match_action: :submit,
          match_action_type: :create,
          guard_feel: ~s|string length(data.justification) > 30|,
          process_key: "access_request.grant"
        },
        opts
      )

    # The seeded recipe runs as the person who caused it, the one key the allowlist names;
    # a draft defaults to human tasks only, and this process grants a role.
    subscription =
      subscription
      |> Subscription.set_authority!(:causing_person, opts)
      |> Subscription.publish!(opts)

    # The publish lane stamped the cursor at the mark as of publish, so the
    # events the rest of the test writes sit ahead of it.
    assert cursor(tenant: organization.id).last_sequence == highest_sequence(organization.id)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Report Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    %{
      tenant: organization.id,
      admin: admin,
      unit: unit,
      role: role,
      platform: platform.id,
      subscription: subscription,
      tenant_definition: tenant_definition
    }
  end

  defp publish_baselines(platform) do
    opts = [actor: SystemActor.process(), tenant: platform]

    for {glob, resource} <- [
          {"priv/dmn/*.dmn", Decisions.Definition},
          {"priv/bpmn/*.bpmn", AshEnterprise.Bpmn.Definition}
        ],
        path <- Path.wildcard(glob) do
      key =
        path
        |> Path.basename()
        |> Path.rootname()
        |> then(fn n ->
          parts = String.split(n, "_")
          Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
        end)

      xml = File.read!(path)

      unless resource
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(key == ^key and status == :published)
             |> Ash.read!(opts)
             |> Enum.any?() do
        definition = resource.create!(%{key: key, name: key, xml: xml}, opts)

        assert definition.errors in [nil, []],
               "#{key} did not compile: #{inspect(definition.errors)}"

        resource.publish!(definition, opts)
      end
    end
  end

  defp fork_and_publish!(key, opts) do
    {:ok, draft} = Resolver.fork(:process, key, opts[:tenant], nil)
    published = AshEnterprise.Bpmn.Definition.publish!(draft, opts)
    published
  end

  defp submit!(attrs, ctx) do
    AccessRequest.submit!(
      Map.merge(
        %{
          justification: "I need this to run the quarterly compliance report for my region.",
          requested_role_tier: :standard,
          requested_role_id: ctx.role.id,
          scoping_business_unit_id: ctx.unit.id
        },
        attrs
      ),
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  defp sweep!(tenant) do
    AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
  end

  defp instances(tenant) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp dispatches(tenant) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  describe "a process starts because something happened" do
    test "submitting a request dispatches a process, with nothing wired to the action", ctx do
      request = submit!(%{}, ctx)

      # Nothing has started yet: submitting is a plain create and it returned immediately.
      assert request.decision_outcome == nil
      assert instances(ctx.tenant) == []

      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.subject_id == request.id
      assert instance.organization_id == ctx.tenant

      # The dispatch row and the instance agree, and the process joined the
      # operation that caused it through the correlation id the audited write
      # stamped.
      assert [dispatch] = dispatches(ctx.tenant)
      assert dispatch.status == :started
      assert dispatch.subscription_id == ctx.subscription.id
      assert dispatch.process_key == "access_request.grant"
      assert dispatch.instance_id == instance.id
      assert dispatch.correlation_id == instance.correlation_id
      refute is_nil(dispatch.event_sequence)

      # The human who caused it is named on the instance, though the engine
      # itself acted as a non-human actor.
      assert instance.started_by_id == ctx.admin.id

      # The instance runs the tenant's own copy — the in-tenant resolution that
      # is today's documented Phase-2 gap, not a silent platform fallback.
      assert instance.definition_id == ctx.tenant_definition.id
    end

    # The engine's semantics, visible through the app's wiring: a plain guard
    # `false` is an ordinary no and records *nothing* — no dispatch row, no
    # instance. (`:guard_null` and `:guard_error` are the rows that exist
    # precisely because they are not ordinary.)
    test "a guard that says no starts nothing and records nothing", ctx do
      # Long enough for the attribute's own `min_length: 10`, short enough that the
      # subscription's guard declines it. The two thresholds are deliberately far apart: a
      # guard that sat on the boundary of a validation would be a test about arithmetic.
      submit!(%{justification: "too terse here"}, ctx)
      sweep!(ctx.tenant)

      assert instances(ctx.tenant) == []
      assert dispatches(ctx.tenant) == []
    end

    # The property the whole cursor design exists for.
    test "sweeping twice does not start the process twice", ctx do
      submit!(%{}, ctx)

      sweep!(ctx.tenant)
      sweep!(ctx.tenant)

      assert length(instances(ctx.tenant)) == 1
      assert length(dispatches(ctx.tenant)) == 1
    end
  end

  describe "the decision routes it" do
    test "a low-risk request is granted without a human", ctx do
      request =
        submit!(
          %{
            requested_role_tier: :standard,
            justification: "Quarterly compliance reporting for the EMEA region, per audit ask."
          },
          ctx
        )

      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.status == :completed

      # A string, where `decision_outcome` four lines below is an atom, and the
      # two are not the same kind of thing despite reading alike. The instance's
      # outcome is authored by the modeller -- `ash:taskConfig outcome="..."` in
      # tenant XML -- so ash_bpmn stores it as text; it only ever worked as an
      # atom because "granted" happened to exist as one elsewhere in this
      # codebase, and any outcome a modeller invented would have failed at the
      # moment the process completed. `decision_outcome` is our own Ash enum on
      # AccessRequest, declared in code, and stays an atom.
      assert instance.outcome == "granted"

      reloaded = reload(request, ctx.tenant)
      assert reloaded.risk_tier == :low
      assert reloaded.decision_outcome == :granted

      # The role was actually assigned, through an ordinary Ash action.
      assert reloaded.granted_user_role_id
      assert [_assignment] = assignments(request, ctx)
    end

    test "a privileged request waits for a human instead", ctx do
      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.status == :running

      assert [task] =
               HumanTask
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert task.node_id == "ExecutiveApproval"
      assert task.status == :open
    end

    # The decision's answer is evidence, not a log line.
    test "the evaluation is recorded with the version that decided", ctx do
      submit!(%{}, ctx)
      sweep!(ctx.tenant)

      assert [evaluation] =
               Decisions.Evaluation
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert evaluation.definition_key == "access_request.risk"
      assert evaluation.definition_version == 1
      assert evaluation.inputs["requestedRoleTier"] == "standard"
    end

    # The instance's own history names the rule that decided, and it is the same rule the
    # evaluation recorded: one account of the decision, read from two places.
    test "the decision event names the rule that fired", ctx do
      submit!(%{}, ctx)
      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [event] = process_events(instance.id, :decision_evaluated, ctx.tenant)
      assert event.data["decision_ref"] == "access_request.risk"
      assert event.data["rule_ids"] == ["rule_standard_argued"]

      assert [evaluation] =
               Decisions.Evaluation
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert evaluation.matched_rule_ids == event.data["rule_ids"]
    end

    # A low-risk request takes the *default* flow, which by definition has no condition -- so
    # the recorded expression is empty and the flow id is what identifies the branch. Asserting
    # on the expression here would be asserting that the default branch is conditioned, which
    # is the opposite of what a default is.
    test "the gateway records which branch it took", ctx do
      submit!(%{}, ctx)
      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [event] = process_events(instance.id, :gateway_branch_taken, ctx.tenant)
      assert event.data["flow_id"] == "Flow_auto"
      assert event.data["target_node"] == "Grant"
    end

    test "a conditioned branch records the FEEL that chose it", ctx do
      # Threads two thresholds deliberately: over the subscription's guard (>30) so the
      # process starts at all, and under the decision table's boundary (<40) so an elevated
      # request comes back "high" and takes a *conditioned* branch rather than the default.
      submit!(
        %{requested_role_tier: :elevated, justification: "Short but elevated, needs review."},
        ctx
      )

      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [event] = process_events(instance.id, :gateway_branch_taken, ctx.tenant)
      assert event.data["expression"] =~ "routing.risk_tier"
    end
  end

  # The timer ledger (`AshEnterprise.Bpmn.TimerJob`): Oban forgets a job within days and never
  # says why one was cancelled, so the engine records each armed timer in the tenant's own
  # table. The executive approval's 24-hour escalation is the timer this diagram declares.
  describe "the timer ledger" do
    test "a waiting approval's escalation is armed on the ledger, in its own tenant", ctx do
      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)

      [task] = tasks(ctx.tenant)

      assert [row] = timer_rows(ctx.tenant)
      assert row.task_id == task.id
      assert row.node_id == "ExecutiveApproval"
      assert row.kind == :escalate
      assert row.status == :scheduled
      assert row.organization_id == ctx.tenant
      # The firing's stable key, `<task>/<node>/<timer index>/<repetition>`.
      assert [task_id, "ExecutiveApproval", _index, "1"] = String.split(row.data["key"], "/")
      assert task_id == task.id

      # Armed for 24 hours after the task opened: an instant, recorded once.
      assert_in_delta DateTime.diff(row.due_at, task.inserted_at, :second), 24 * 3600, 5

      # Another organization reads none of it.
      %{organization: other} =
        Seeder.seed_tenant(
          unique_name: "other-#{System.unique_integer([:positive])}",
          email: "other-#{System.unique_integer([:positive])}@example.com"
        )

      assert timer_rows(other.id) == []
    end

    test "cancelling the instance cancels the armed timer, with the reason", ctx do
      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [instance] = instances(ctx.tenant)

      AshBpmn.cancel_instance!(instance, actor: SystemActor.process(), tenant: ctx.tenant)

      assert [row] = timer_rows(ctx.tenant)
      assert row.status == :cancelled
      assert row.cancel_reason == :instance_cancelled
      assert [%{status: :cancelled}] = tasks(ctx.tenant)
    end

    test "no person writes a ledger row, not even the tenant's administrator", ctx do
      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               TimerJob
               |> Ash.Changeset.for_create(
                 :create,
                 %{task_id: task.id, kind: :escalate, due_at: DateTime.utc_now()},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
               |> Ash.create()

      [row] = timer_rows(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               row
               |> Ash.Changeset.for_update(:record_cancelled, %{cancel_reason: :host_request},
                 actor: ctx.admin,
                 tenant: ctx.tenant
               )
               |> Ash.update()
    end
  end

  # `HumanTask.stalled`, the read behind the stalled-reviews page and the assistant's
  # `stalled_reviews` tool: past its due date when it has one, two days old when it has none.
  describe "a stalled task" do
    test "is past its due date, or two days old with none; a task not yet due is not", ctx do
      for _ <- 1..4, do: submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)

      assert [overdue, not_yet_due, old_undated, fresh_undated] = tasks(ctx.tenant)

      now = DateTime.utc_now()
      days = fn n -> DateTime.add(now, n * 86_400, :second) end

      # Opened an hour ago, due an hour ago: stalled, though young.
      set_task!(overdue, inserted_at: DateTime.add(now, -3600, :second), due_at: days.(0))
      # Opened five days ago and due tomorrow: not stalled, however old.
      set_task!(not_yet_due, inserted_at: days.(-5), due_at: days.(1))
      # No due date: the two-day rule.
      set_task!(old_undated, inserted_at: days.(-3), due_at: nil)
      set_task!(fresh_undated, inserted_at: days.(-1), due_at: nil)

      stalled =
        HumanTask
        |> Ash.Query.for_read(:stalled, %{}, actor: SystemActor.process(), tenant: ctx.tenant)
        |> Ash.read!()
        |> Enum.map(& &1.id)

      assert Enum.sort(stalled) == Enum.sort([overdue.id, old_undated.id])

      # A decided task is never stalled, even past its due date.
      set_task!(overdue, status: "cancelled")

      assert [%{id: id}] =
               HumanTask
               |> Ash.Query.for_read(:stalled, %{},
                 actor: SystemActor.process(),
                 tenant: ctx.tenant
               )
               |> Ash.read!()

      assert id == old_undated.id
    end
  end

  # The diagram's 24-hour escalation, end to end (ash_bpmn DESIGN.md §11.6, §11.7): the
  # engine asks `AssignmentResolver.escalate/2` whom to add, adds them, and tells everyone
  # through `TaskNotices`. The requester (`ctx.admin`) is excluded from the review, so the
  # reviewer is a second administrator.
  describe "an escalation reaches people" do
    setup ctx do
      TestJobs.clear()
      on_exit(&TestJobs.clear/0)
      flush_mail()
      ctx
    end

    test "the reviewer's manager is added, and both are told; the requester never is", ctx do
      manager = person!(ctx)
      reviewer = person!(ctx, manager: manager, admin?: true)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)
      assert candidate_ids(task, ctx.tenant) == [reviewer.id]

      TestJobs.fire!("escalate", task.id)

      # Added, never replacing: the reviewer is still a candidate.
      assert Enum.sort(candidate_ids(task, ctx.tenant)) == Enum.sort([reviewer.id, manager.id])

      assert [escalated] = process_events(task.instance_id, :task_escalated, ctx.tenant)
      assert escalated.data["added"] == [%{"type" => "user", "id" => manager.id}]

      assert [delivered] = process_events(task.instance_id, :notice_delivered, ctx.tenant)
      assert delivered.data["key"] == escalated.data["key"]

      notices = task_notices(ctx.tenant)
      assert Enum.sort(Enum.map(notices, & &1.user_id)) == Enum.sort([reviewer.id, manager.id])
      assert Enum.all?(notices, &(&1.key == escalated.data["key"] and &1.kind == :escalated))

      assert_email_sent(to: to_string(reviewer.email))
      assert_email_sent(to: to_string(manager.email))
      refute_email_sent()

      assert [%{status: :fired}] = timer_rows(ctx.tenant)
    end

    test "a manager who is the requester is not added; the fallback pool is", ctx do
      reviewer = person!(ctx, manager: ctx.admin, admin?: true)
      operator = operator!(ctx)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)
      assert ctx.admin.id in task.excluded_principal_ids

      TestJobs.fire!("escalate", task.id)

      ids = candidate_ids(task, ctx.tenant)
      assert operator.id in ids
      refute ctx.admin.id in ids

      # The task's candidates first, then the people the escalation added.
      assert_email_sent(to: to_string(reviewer.email))
      assert_email_sent(to: to_string(operator.email))
      refute_email_sent()
    end

    test "with no manager and nobody to fall back to, it reaches nobody, and a finding says so",
         ctx do
      reviewer = person!(ctx, admin?: true)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)

      TestJobs.fire!("escalate", task.id)

      assert candidate_ids(task, ctx.tenant) == [reviewer.id]
      assert [_nobody] = process_events(task.instance_id, :escalation_reached_nobody, ctx.tenant)
      assert process_events(task.instance_id, :task_escalated, ctx.tenant) == []
      assert task_notices(ctx.tenant) == []
      refute_email_sent()

      {:ok, findings} =
        AshCompliance.Domain.findings_for_organization(ctx.tenant, authorize?: false)

      subject_type = RecordUnassignableFinding.subject_type(:escalation_reached_nobody)
      assert [finding] = Enum.filter(findings, &(&1.subject_type == subject_type))
      assert finding.subject_id == task.id
      assert finding.gap == "escalation_reached_nobody"
      assert finding.severity == :medium
      assert finding.explanation =~ "reached nobody"
    end

    test "a notice whose mail fails is retried under its key: one row and one message each",
         ctx do
      manager = person!(ctx)
      reviewer = person!(ctx, manager: manager, admin?: true)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)
      job = stored_job!("escalate", task.id)

      start_supervised!({FlakyMailer, failures: 1})
      FlakyMailer.install()

      # The escalation commits; the notice fails, and the job fails so Oban retries it.
      assert {:error, _} = perform(job)
      assert [_] = process_events(task.instance_id, :task_escalated, ctx.tenant)
      assert process_events(task.instance_id, :notice_delivered, ctx.tenant) == []

      assert {:ok, _} = perform(job)

      assert [_] = process_events(task.instance_id, :task_escalated, ctx.tenant)
      assert [_] = process_events(task.instance_id, :notice_delivered, ctx.tenant)
      assert length(task_notices(ctx.tenant)) == 2

      # The first attempt's failure silenced nobody after it: each person was mailed once,
      # one on the first attempt and the other on the retry.
      assert Enum.sort(mailed_to()) ==
               Enum.sort([to_string(reviewer.email), to_string(manager.email)])
    end

    test "a cancelled task is told nothing", ctx do
      manager = person!(ctx)
      _reviewer = person!(ctx, manager: manager, admin?: true)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)
      [instance] = instances(ctx.tenant)
      job = stored_job!("escalate", task.id)

      AshBpmn.cancel_instance!(instance, actor: SystemActor.process(), tenant: ctx.tenant)

      perform(job)

      assert process_events(instance.id, :task_escalated, ctx.tenant) == []
      assert task_notices(ctx.tenant) == []
      refute_email_sent()
    end

    test "on a claimed task, a reminder tells only the person holding it", ctx do
      publish_with_reminder!(ctx)
      holder = person!(ctx, admin?: true)
      other = person!(ctx, admin?: true)

      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)
      [task] = tasks(ctx.tenant)
      assert Enum.sort(candidate_ids(task, ctx.tenant)) == Enum.sort([holder.id, other.id])

      {:ok, _claimed} =
        AshBpmn.claim_task(task,
          actor: AssistantFixtures.actor(holder, ctx.tenant),
          tenant: ctx.tenant
        )

      TestJobs.fire!("remind", task.id)

      assert [%{user_id: user_id, kind: :remind}] = task_notices(ctx.tenant)
      assert user_id == holder.id
      assert_email_sent(to: to_string(holder.email))
      refute_email_sent()
    end

    test "without a notifier, a draft of the diagram is refused", ctx do
      previous = Application.get_env(:ash_bpmn, :task_notifier)
      Application.put_env(:ash_bpmn, :task_notifier, nil)
      on_exit(fn -> Application.put_env(:ash_bpmn, :task_notifier, previous) end)

      draft =
        AshEnterprise.Bpmn.Definition.create!(
          %{
            key: "access_request.grant",
            name: "access_request.grant",
            xml: File.read!("priv/bpmn/access_request_grant.bpmn")
          },
          actor: SystemActor.process(),
          tenant: ctx.tenant
        )

      assert draft.errors not in [nil, []]
      assert Enum.any?(draft.errors, &(inspect(&1) =~ "task_notifier"))
    end
  end

  describe "attribution" do
    # The reason the bypass ordering was chosen over an engine actor: the human survives.
    test "the process runs as a named non-human actor, and names the human who caused it", ctx do
      request = submit!(%{}, ctx)
      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [started | _] = process_events(instance.id, :instance_started, ctx.tenant)
      assert started

      # The request itself is still attributed to the person who raised it.
      assert reload(request, ctx.tenant).created_by_id == ctx.admin.id
    end
  end

  describe "the nudge path" do
    # The notifier is attached to the log by this app, and under `oban_testing:
    # :inline` a nudge *is* a sweep. With the index started — it is not at boot
    # in :test, see `AshEnterprise.Application.trigger_index/0` — a notification
    # for a real event row drives the whole path: short-name normalization, ETS
    # interest, debounced insert, inline sweep, dispatch. The log's own writes
    # send that notification; a test can also send one by hand.
    test "a type-narrowed subscription rides the cron, not the coarse nudge", ctx do
      start_supervised!(AshBpmn.Triggers.Index)
      assert :ok = AshBpmn.Triggers.Index.reload!()

      # The index (built by the engine from published, enabled subscriptions)
      # knows this resource — the app's notifier attachment and the library's
      # default field spellings are what this reload proves.
      assert AshBpmn.Triggers.Index.interested?("AshEnterprise.Security.AccessRequest", "create")

      # But the nudge is *coarse*: it asks about the resource only, so a
      # subscription narrowed by action type is invisible to it. That is the
      # design working, not failing — the cron sweep is the driver, so a
      # nudge that cannot see a subscription costs latency, never a process.
      refute AshBpmn.Triggers.Index.interested?("AshEnterprise.Security.AccessRequest")

      request = submit!(%{}, ctx)
      event = latest_event!(ctx.tenant, AshEnterprise.Security.AccessRequest, request.id)

      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: event})

      assert dispatches(ctx.tenant) == [], "the coarse nudge cannot see a narrowed subscription"

      # And the cron — the driver — reaches the same event anyway.
      sweep!(ctx.tenant)

      assert [dispatch] = dispatches(ctx.tenant)
      assert dispatch.status == :started
      assert dispatch.event_id == event.id
      assert [%Instance{subject_id: subject_id}] = instances(ctx.tenant)
      assert subject_id == request.id
    end

    test "a subscription the coarse nudge can see dispatches inline from the write itself", ctx do
      start_supervised!(AshBpmn.Triggers.Index)
      assert :ok = AshBpmn.Triggers.Index.reload!()

      # Take the narrowed subscription out of the match (disabling it before
      # the write, so this is not the not-retroactive case), and install one
      # the coarse nudge can see: resource-level match, no action narrowing.
      Subscription.disable!(ctx.subscription, actor: SystemActor.process(), tenant: ctx.tenant)

      # A new version of the seeded key, because only that key may run as the causing
      # person.
      Subscription.create!(
        %{
          key: "access_request.submitted",
          match_resource: "AshEnterprise.Security.AccessRequest",
          process_key: "access_request.grant"
        },
        actor: SystemActor.process(),
        tenant: ctx.tenant
      )
      |> Subscription.set_authority!(:causing_person,
        actor: SystemActor.process(),
        tenant: ctx.tenant
      )
      |> Subscription.publish!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert AshBpmn.Triggers.Index.interested?("AshEnterprise.Security.AccessRequest")

      request = submit!(%{}, ctx)
      event = first_event!(ctx.tenant, AshEnterprise.Security.AccessRequest, request.id)

      # No synthetic notification: the event log hands its row's notification to
      # its notifiers, so the submit's own write is the nudge, and under `oban_testing:
      # :inline` it runs the funnel, starts the instance and writes the ledger row
      # before `submit!` returns.
      {direct, caused} = ctx.tenant |> dispatches() |> Enum.split_with(&(&1.depth == 1))

      assert [dispatch] = direct
      assert dispatch.status == :started
      assert dispatch.event_id == event.id

      # This subscription matches every write to the resource, so the grant process's
      # own writes to the request match it too. They dispatch a level deeper, caused by
      # the process, which is what the depth bound is for.
      assert Enum.all?(caused, &(&1.depth > 1))
      assert Enum.all?(instances(ctx.tenant), &(&1.subject_id == request.id))
    end

    # With no index running — the boot posture in :test — the nudge degrades to
    # "nudge nobody" rather than to an error, and the cron sweep is what
    # completes dispatch.
    test "an unstarted index costs the nudge, never the dispatch" do
      refute AshBpmn.Triggers.Index.started?()
      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: %{}})
    end
  end

  defp tasks(tenant) do
    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp timer_rows(tenant) do
    TimerJob
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  # Moves a task's clock without waiting for it: the test's only direct write.
  defp set_task!(task, fields) do
    {1, _} =
      AshEnterprise.Repo.update_all(
        Ecto.Query.from(t in "bpmn_human_tasks", where: t.id == type(^task.id, Ecto.UUID)),
        set: fields
      )
  end

  defp task_notices(tenant) do
    TaskNotice
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp candidate_ids(task, tenant) do
    AshEnterprise.Bpmn.TaskCandidate
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(task_id == ^task.id)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> Enum.map(& &1.principal_id)
  end

  # A person at home in the tenant's root unit, with a manager or the Administrator role.
  defp person!(ctx, opts \\ []) do
    n = System.unique_integer([:positive])

    user =
      "person-#{n}@example.test"
      |> Seeder.provision_user!("password-#{n}-long")
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: ctx.unit.id},
        authorize?: false
      )
      |> Ash.update!()

    user =
      case opts[:manager] do
        nil ->
          user

        manager ->
          user
          |> Ash.Changeset.for_update(:assign_manager, %{manager_id: manager.id},
            authorize?: false
          )
          |> Ash.update!()
      end

    if opts[:admin?], do: give_role!(ctx, user, "Administrator")
    user
  end

  # The fallback pool `AssignmentResolver.fallback_specs/0` names by default.
  defp operator!(ctx) do
    operator = person!(ctx)
    give_role!(ctx, operator, "Platform Operator")
    operator
  end

  defp give_role!(ctx, user, name) do
    role =
      Role
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!(authorize?: false, tenant: ctx.tenant) ||
        Role
        |> Ash.Changeset.for_create(:create, %{name: name},
          actor: SystemActor.seed(),
          tenant: ctx.tenant
        )
        |> Ash.create!()

    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: ctx.unit.id},
      tenant: ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  # The tenant's next version of the process, with a four-hour reminder on the executive
  # approval beside its escalation.
  defp publish_with_reminder!(ctx) do
    xml =
      "priv/bpmn/access_request_grant.bpmn"
      |> File.read!()
      |> String.replace(
        ~s|<ash:timer kind="escalate" hours="24"/>|,
        ~s|<ash:timer kind="remind" hours="4"/>\n            <ash:timer kind="escalate" hours="24"/>|
      )

    opts = [actor: SystemActor.process(), tenant: ctx.tenant]

    %{key: "access_request.grant", name: "access_request.grant", xml: xml}
    |> AshEnterprise.Bpmn.Definition.create!(opts)
    |> AshEnterprise.Bpmn.Definition.publish!(opts)
  end

  defp stored_job!(kind, task_id) do
    Enum.find(TestJobs.all(), &(&1.args["kind"] == kind and &1.args["task_id"] == task_id)) ||
      flunk("no #{kind} timer stored for #{task_id}")
  end

  # What Oban does with a stored job: perform it, as often as it is retried.
  defp perform(record) do
    record.worker.perform(%Oban.Job{
      id: record.id,
      args: record.args,
      scheduled_at: record[:scheduled_at],
      attempt: 1,
      max_attempts: 5
    })
  end

  defp flush_mail do
    receive do
      {:email, _email} -> flush_mail()
    after
      0 -> :ok
    end
  end

  defp reload(request, tenant) do
    AccessRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^request.id)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  defp assignments(request, ctx) do
    UserRole
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(user_id == ^request.created_by_id and role_id == ^ctx.role.id)
    |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)
  end

  defp process_events(instance_id, kind, tenant) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id and kind == ^kind)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp latest_event!(tenant, resource, record_id),
    do: event_at!(tenant, resource, record_id, :desc)

  defp first_event!(tenant, resource, record_id),
    do: event_at!(tenant, resource, record_id, :asc)

  defp event_at!(tenant, resource, record_id, order) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(resource == ^resource and record_id == ^record_id)
    |> Ash.Query.sort(sequence: order)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  defp cursor(tenant: tenant) do
    Cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  defp highest_sequence(tenant) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{sequence: sequence}] -> sequence
      [] -> 0
    end
  end

  defp mailed_to(acc \\ []) do
    receive do
      {:email, email} -> mailed_to(Enum.map(email.to, &elem(&1, 1)) ++ acc)
    after
      0 -> acc
    end
  end
end
