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

  require Ash.Query

  alias AshEnterprise.Bpmn.Subscription
  alias AshEnterprise.Bpmn.{Cursor, Dispatch, HumanTask, Instance, ProcessEvent}
  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security.{AccessRequest, Role, UserRole}

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

    subscription = Subscription.publish!(subscription, opts)

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
      assert instance.outcome == :granted

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
    # in :test, see `AshEnterprise.Application.trigger_index/0` — a synthetic
    # notification for a real event row drives the whole path: short-name
    # normalization, ETS interest, debounced insert, inline sweep, dispatch.
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

    test "a subscription the coarse nudge can see dispatches inline on the nudge alone", ctx do
      start_supervised!(AshBpmn.Triggers.Index)
      assert :ok = AshBpmn.Triggers.Index.reload!()

      # Take the narrowed subscription out of the match (disabling it before
      # the write, so this is not the not-retroactive case), and install one
      # the coarse nudge can see: resource-level match, no action narrowing.
      Subscription.disable!(ctx.subscription, actor: SystemActor.process(), tenant: ctx.tenant)

      Subscription.create!(
        %{
          key: "access_request.submitted.coarse",
          match_resource: "AshEnterprise.Security.AccessRequest",
          process_key: "access_request.grant"
        },
        actor: SystemActor.process(),
        tenant: ctx.tenant
      )
      |> Subscription.publish!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert AshBpmn.Triggers.Index.interested?("AshEnterprise.Security.AccessRequest")

      request = submit!(%{}, ctx)
      event = latest_event!(ctx.tenant, AshEnterprise.Security.AccessRequest, request.id)

      # The nudge *is* the sweep here: under `oban_testing: :inline` the
      # debounced insert executes the worker synchronously, so this one
      # notifier call runs the funnel, starts the instance and writes the
      # ledger row.
      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: event})

      assert [dispatch] = dispatches(ctx.tenant)
      assert dispatch.status == :started
      assert dispatch.event_id == event.id
      assert [%Instance{subject_id: subject_id}] = instances(ctx.tenant)
      assert subject_id == request.id
    end

    # With no index running — the boot posture in :test — the nudge degrades to
    # "nudge nobody" rather than to an error, and the cron sweep is what
    # completes dispatch.
    test "an unstarted index costs the nudge, never the dispatch" do
      refute AshBpmn.Triggers.Index.started?()
      assert :ok = AshBpmn.Triggers.Nudge.notify(%Ash.Notifier.Notification{data: %{}})
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

  defp latest_event!(tenant, resource, record_id) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(resource == ^resource and record_id == ^record_id)
    |> Ash.Query.sort(sequence: :desc)
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
end
